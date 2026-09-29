#!/usr/bin/env python3
"""Export published WordPress content to files, or restore it into any WordPress site.

    export   read a site over its REST API into content/wordpress/ (deterministic
             output, so an unchanged site produces no git diff)
    restore  recreate that content on a (usually fresh) site: categories, tags,
             media, posts, pages, reusable blocks, navigation, site-editor
             customizations (templates, template parts, global styles) and a
             safe subset of settings. Idempotent: re-running updates by slug.

Only *published* content is exported, and never anything private: no users,
emails, comments, drafts or database dump. The output is meant to be safe to
commit to a public repository.

Auth is a WordPress Application Password (Users -> Profile -> Application
Passwords), passed via the WP_APP_PASSWORD environment variable, never on the
command line. Standard library only.

Examples:
    WP_APP_PASSWORD=... python3 scripts/wp_content.py export \\
        --url https://blog.example.com --user admin --out content
    WP_APP_PASSWORD=... python3 scripts/wp_content.py restore \\
        --url https://new-site.example.com --user admin --src content --dry-run
"""

import argparse
import base64
import json
import mimetypes
import os
import pathlib
import re
import shutil
import sys
import urllib.error
import urllib.parse
import urllib.request

EXPORT_DIR = "wordpress"

# Settings worth carrying to a new site. Deliberately excludes "email" (the
# admin address) and "url" (belongs to the target site).
SETTINGS_KEYS = [
    "title", "description", "timezone", "date_format", "time_format",
    "start_of_week", "posts_per_page", "show_on_front", "page_on_front",
    "page_for_posts", "default_category", "default_post_format",
    "default_comment_status", "default_ping_status", "site_logo", "site_icon",
]

POST_FIELDS = [
    "id", "date_gmt", "slug", "status", "type", "categories", "tags",
    "featured_media", "comment_status", "ping_status", "sticky", "format",
    "template", "parent", "menu_order",
]


class WP:
    def __init__(self, url, user, password):
        self.base = url.rstrip("/")
        self.auth = "Basic " + base64.b64encode(f"{user}:{password}".encode()).decode()
        self.api = self._discover_api_root()

    def _discover_api_root(self):
        # Plain permalinks put the API under /index.php/wp-json/; the homepage's
        # Link header says where it actually is.
        req = urllib.request.Request(self.base + "/", method="HEAD")
        try:
            with urllib.request.urlopen(req, timeout=30) as r:
                link = r.headers.get("Link", "")
        except urllib.error.HTTPError as e:
            link = e.headers.get("Link", "")
        m = re.search(r'<([^>]+)>;\s*rel="https://api\.w\.org/"', link)
        root = m.group(1) if m else self.base + "/wp-json/"
        return root if "rest_route=" in root else root.rstrip("/")

    def call(self, method, route, params=None, body=None, headers=None):
        """Returns (json_or_bytes, response_headers).

        Reads are sent as POST with _method=GET: CloudFront only forwards the
        Authorization header on non-GET requests unless it's part of the cache
        key, and WordPress treats _method=GET as a read.
        """
        params = dict(params or {})
        if method == "GET":
            method, params["_method"] = "POST", "GET"
        if "rest_route=" in self.api:
            # Plain permalinks: the root is index.php?rest_route=/
            url, params["rest_route"] = self.api.split("?", 1)[0], route
        else:
            url = self.api + route
        if params:
            url += "?" + urllib.parse.urlencode(params, doseq=True)
        hdrs = {"Authorization": self.auth, "Accept": "application/json"}
        data = b""
        if isinstance(body, (dict, list)):
            data = json.dumps(body).encode()
            hdrs["Content-Type"] = "application/json"
        elif isinstance(body, bytes):
            data = body
        hdrs.update(headers or {})
        req = urllib.request.Request(url, data=data, method=method, headers=hdrs)
        try:
            with urllib.request.urlopen(req, timeout=120) as r:
                raw = r.read()
                return (json.loads(raw) if raw else None), r.headers
        except urllib.error.HTTPError as e:
            detail = e.read().decode(errors="replace")[:500]
            raise SystemExit(f"{method} {route} -> HTTP {e.code}: {detail}")

    def get_all(self, route, params=None):
        items, page = [], 1
        while True:
            batch, hdrs = self.call("GET", route, {**(params or {}), "per_page": 100, "page": page})
            items.extend(batch)
            if page >= int(hdrs.get("X-WP-TotalPages") or 1):
                return items
            page += 1

    def check_auth(self):
        me, _ = self.call("GET", "/wp/v2/users/me", {"context": "edit"})
        caps = me.get("capabilities", {})
        if not caps.get("edit_theme_options"):
            print("warning: this user can't read/write site-editor content "
                  "(templates, global styles); an administrator is needed for those.")


def raw(field):
    return field.get("raw", field.get("rendered", "")) if isinstance(field, dict) else (field or "")


def write_json(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(data, indent=2, sort_keys=True, ensure_ascii=False) + "\n")


def write_text(path, text):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text if text.endswith("\n") else text + "\n")


def read_json(path, default=None):
    return json.loads(path.read_text()) if path.exists() else default


# ------------------------------------------------------------------ export

def export(wp, out_root):
    out_root = pathlib.Path(out_root)
    tmp = out_root / (EXPORT_DIR + ".tmp")
    shutil.rmtree(tmp, ignore_errors=True)

    write_json(tmp / "site.json", {"source_url": wp.base})

    for kind in ("categories", "tags"):
        terms = wp.get_all(f"/wp/v2/{kind}", {"context": "edit"})
        write_json(tmp / f"{kind}.json", sorted(
            [{k: t.get(k) for k in ("id", "name", "slug", "description", "parent") if k in t}
             for t in terms], key=lambda t: t["slug"]))

    media = wp.get_all("/wp/v2/media", {"context": "edit"})
    media_meta = []
    for m in media:
        name = f"{m['id']}-{pathlib.PurePosixPath(urllib.parse.urlparse(m['source_url']).path).name}"
        with urllib.request.urlopen(m["source_url"], timeout=120) as r:
            (tmp / "media").mkdir(parents=True, exist_ok=True)
            (tmp / "media" / name).write_bytes(r.read())
        media_meta.append({
            "id": m["id"], "file": name, "slug": m["slug"], "date_gmt": m["date_gmt"],
            "title": raw(m["title"]), "alt_text": m.get("alt_text", ""),
            "caption": raw(m.get("caption")), "description": raw(m.get("description")),
            "mime_type": m["mime_type"], "source_url": m["source_url"],
        })
    write_json(tmp / "media.json", sorted(media_meta, key=lambda m: m["id"]))

    counts = {"media": len(media_meta)}
    for kind, route in (("posts", "/wp/v2/posts"), ("pages", "/wp/v2/pages"),
                        ("blocks", "/wp/v2/blocks"), ("navigation", "/wp/v2/navigation")):
        items = wp.get_all(route, {"context": "edit", "status": "publish"})
        for it in items:
            d = tmp / kind / it["slug"]
            meta = {k: it[k] for k in POST_FIELDS if k in it}
            meta["title"] = raw(it.get("title"))
            meta["excerpt"] = raw(it.get("excerpt"))
            write_json(d / "meta.json", meta)
            write_text(d / "content.html", raw(it.get("content")))
        counts[kind] = len(items)

    # Site editor: only what the user customized (source "custom"), not theme defaults.
    theme = wp.call("GET", "/wp/v2/themes", {"status": "active"})[0][0]
    write_json(tmp / "theme.json", {"stylesheet": theme["stylesheet"]})
    for kind in ("templates", "template-parts"):
        items = [t for t in wp.get_all(f"/wp/v2/{kind}", {"context": "edit"})
                 if t.get("source") == "custom"]
        for t in items:
            d = tmp / kind / t["slug"]
            write_json(d / "meta.json", {k: t.get(k) for k in ("id", "slug", "theme", "area", "description")
                                         if t.get(k) is not None} | {"title": raw(t.get("title"))})
            write_text(d / "content.html", raw(t.get("content")))
        counts[kind] = len(items)

    gs_link = theme.get("_links", {}).get("wp:user-global-styles", [{}])[0].get("href")
    if gs_link:
        gs_id = gs_link.rstrip("/").rsplit("/", 1)[-1]
        gs, _ = wp.call("GET", f"/wp/v2/global-styles/{gs_id}", {"context": "edit"})
        if gs.get("settings") or gs.get("styles"):
            write_json(tmp / "global-styles.json", {"settings": gs.get("settings") or {},
                                                    "styles": gs.get("styles") or {}})

    settings, _ = wp.call("GET", "/wp/v2/settings")
    write_json(tmp / "settings.json", {k: settings[k] for k in SETTINGS_KEYS if k in settings})

    final = out_root / EXPORT_DIR
    shutil.rmtree(final, ignore_errors=True)
    tmp.rename(final)
    print("exported:", ", ".join(f"{k}={v}" for k, v in counts.items()))


# ----------------------------------------------------------------- restore

BLOCK_ID_RE = re.compile(r'(<!-- wp:(?:image|cover|media-text|video|audio|file)\s+)(\{.*?\})(\s*/?-->)')


def rewrite_content(html, id_map, url_map, old_base, new_base):
    for old, new in url_map.items():
        html = html.replace(old, new)
    html = re.sub(r"wp-image-(\d+)", lambda m: f"wp-image-{id_map.get(int(m.group(1)), m.group(1))}", html)

    def fix_attrs(m):
        attrs = json.loads(m.group(2))
        for key in ("id", "mediaId"):
            if isinstance(attrs.get(key), int) and attrs[key] in id_map:
                attrs[key] = id_map[attrs[key]]
        return m.group(1) + json.dumps(attrs, separators=(",", ":")) + m.group(3)

    html = BLOCK_ID_RE.sub(fix_attrs, html)
    if old_base and new_base and old_base != new_base:
        html = html.replace(old_base, new_base)
    return html


def upsert(wp, route, slug, body, dry, label):
    existing, _ = wp.call("GET", route, {"slug": slug, "context": "edit", "status": "any"}) \
        if route not in ("/wp/v2/categories", "/wp/v2/tags") else wp.call("GET", route, {"slug": slug})
    if dry:
        print(f"  would {'update' if existing else 'create'} {label} {slug}")
        return existing[0]["id"] if existing else -1
    if existing:
        item, _ = wp.call("POST", f"{route}/{existing[0]['id']}", body=body)
    else:
        item, _ = wp.call("POST", route, body=body)
    print(f"  {'updated' if existing else 'created'} {label} {slug} (id {item['id']})")
    return item["id"]


def depth_sorted(items, parent_key="parent"):
    by_id = {i["id"]: i for i in items}

    def depth(i, seen=()):
        p = i.get(parent_key) or 0
        return 0 if not p or p not in by_id or p in seen else 1 + depth(by_id[p], seen + (p,))
    return sorted(items, key=depth)


def restore(wp, src_root, dry):
    src = pathlib.Path(src_root) / EXPORT_DIR
    if not src.is_dir():
        raise SystemExit(f"{src} not found - run export first")
    old_base = read_json(src / "site.json", {}).get("source_url")
    new_base = wp.base

    term_map = {"categories": {}, "tags": {}}
    for kind in ("categories", "tags"):
        for t in depth_sorted(read_json(src / f"{kind}.json", [])):
            body = {"name": t["name"], "slug": t["slug"], "description": t.get("description", "")}
            if t.get("parent"):
                body["parent"] = term_map[kind].get(t["parent"], 0)
            label = {"categories": "category", "tags": "tag"}[kind]
            term_map[kind][t["id"]] = upsert(wp, f"/wp/v2/{kind}", t["slug"], body, dry, label)

    media_map, url_map = {}, {}
    for m in read_json(src / "media.json", []):
        existing, _ = wp.call("GET", "/wp/v2/media", {"slug": m["slug"], "context": "edit"})
        if dry:
            print(f"  would {'reuse' if existing else 'upload'} media {m['file']}")
            continue
        if existing:
            new = existing[0]
        else:
            data = (src / "media" / m["file"]).read_bytes()
            filename = m["file"].split("-", 1)[1]
            new, _ = wp.call("POST", "/wp/v2/media", body=data, headers={
                "Content-Type": m["mime_type"] or mimetypes.guess_type(filename)[0] or "application/octet-stream",
                "Content-Disposition": f'attachment; filename="{filename}"'})
            new, _ = wp.call("POST", f"/wp/v2/media/{new['id']}", body={
                "title": m["title"], "alt_text": m["alt_text"], "caption": m["caption"],
                "description": m["description"], "slug": m["slug"]})
            print(f"  uploaded media {m['file']} (id {new['id']})")
        media_map[m["id"]] = new["id"]
        # Map the original and every generated size (name-300x200.jpg etc.).
        old_stem, old_ext = os.path.splitext(m["source_url"])
        new_stem, new_ext = os.path.splitext(new["source_url"])
        url_map[m["source_url"]] = new["source_url"]
        for size in (new.get("media_details") or {}).get("sizes", {}).values():
            suffix = size["source_url"][len(new_stem):]
            if size["source_url"].startswith(new_stem):
                url_map[old_stem + suffix.replace(new_ext, old_ext)] = size["source_url"]

    def rw(text):
        return rewrite_content(text, media_map, url_map, old_base, new_base)

    post_map = {}
    for kind in ("pages", "posts", "blocks", "navigation"):
        route = {"pages": "/wp/v2/pages", "posts": "/wp/v2/posts",
                 "blocks": "/wp/v2/blocks", "navigation": "/wp/v2/navigation"}[kind]
        entries = [(read_json(d / "meta.json"), (d / "content.html").read_text())
                   for d in sorted((src / kind).glob("*")) if (d / "meta.json").exists()]
        metas = depth_sorted([e[0] for e in entries])
        content_by_id = {e[0]["id"]: e[1] for e in entries}
        for meta in metas:
            body = {"title": meta.get("title", ""), "content": rw(content_by_id[meta["id"]]),
                    "slug": meta["slug"], "status": "publish"}
            if kind in ("posts", "pages"):
                body.update({"excerpt": rw(meta.get("excerpt", "")), "date_gmt": meta.get("date_gmt"),
                             "comment_status": meta.get("comment_status", "closed"),
                             "ping_status": meta.get("ping_status", "closed"),
                             "featured_media": media_map.get(meta.get("featured_media"), 0)})
                if meta.get("template"):
                    body["template"] = meta["template"]
            if kind == "posts":
                body.update({"categories": [term_map["categories"][c] for c in meta.get("categories", [])
                                            if c in term_map["categories"]],
                             "tags": [term_map["tags"][t] for t in meta.get("tags", []) if t in term_map["tags"]],
                             "sticky": meta.get("sticky", False), "format": meta.get("format", "standard")})
            if kind == "pages":
                body.update({"parent": post_map.get(meta.get("parent"), 0), "menu_order": meta.get("menu_order", 0)})
            post_map[meta["id"]] = upsert(wp, route, meta["slug"], body, dry, kind.rstrip("s"))

    theme = wp.call("GET", "/wp/v2/themes", {"status": "active"})[0][0]
    exported_theme = read_json(src / "theme.json", {}).get("stylesheet")
    if exported_theme and exported_theme != theme["stylesheet"]:
        print(f"warning: exported theme '{exported_theme}' != active theme '{theme['stylesheet']}'; "
              "skipping templates, template parts and global styles. Activate it and re-run.")
    else:
        for kind in ("templates", "template-parts"):
            for d in sorted((src / kind).glob("*")):
                meta = read_json(d / "meta.json")
                tid = f"{theme['stylesheet']}//{meta['slug']}"
                body = {"content": rw((d / "content.html").read_text()), "title": meta.get("title", "")}
                if meta.get("area"):
                    body["area"] = meta["area"]
                if dry:
                    print(f"  would set {kind[:-1]} {tid}")
                    continue
                # POSTing to a theme-provided template's id stores a custom override.
                try:
                    wp.call("POST", f"/wp/v2/{kind}/{tid}", body=body)
                except SystemExit as e:
                    if "HTTP 404" not in str(e):
                        raise
                    wp.call("POST", f"/wp/v2/{kind}", body=body | {"slug": meta["slug"]})
                print(f"  set {kind[:-1]} {tid}")
        gs = read_json(src / "global-styles.json")
        gs_link = theme.get("_links", {}).get("wp:user-global-styles", [{}])[0].get("href")
        if gs and gs_link:
            gs_id = gs_link.rstrip("/").rsplit("/", 1)[-1]
            if dry:
                print("  would set global styles")
            else:
                wp.call("POST", f"/wp/v2/global-styles/{gs_id}", body=gs)
                print("  set global styles")

    settings = read_json(src / "settings.json", {})
    for key, mapping in (("page_on_front", post_map), ("page_for_posts", post_map),
                         ("default_category", term_map["categories"]),
                         ("site_logo", media_map), ("site_icon", media_map)):
        if settings.get(key):
            settings[key] = mapping.get(settings[key], 0)
    # WordPress rejects 0 for these ("cannot be updated to null"): only send a real logo/icon.
    for key in ("site_logo", "site_icon"):
        if not settings.get(key):
            settings.pop(key, None)
    if dry:
        print(f"  would set settings: {', '.join(sorted(settings))}")
    else:
        wp.call("POST", "/wp/v2/settings", body=settings)
        print("  set settings")
    print("restore complete" + (" (dry run, nothing written)" if dry else ""))


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    for name in ("export", "restore"):
        p = sub.add_parser(name)
        p.add_argument("--url", required=True, help="site URL, e.g. https://blog.example.com")
        p.add_argument("--user", required=True, help="WordPress username that owns the application password")
        if name == "export":
            p.add_argument("--out", default="content", help="directory to write content/wordpress/ into")
        else:
            p.add_argument("--src", default="content", help="directory containing wordpress/")
            p.add_argument("--dry-run", action="store_true", help="show what would change, write nothing")
    args = ap.parse_args()

    password = os.environ.get("WP_APP_PASSWORD")
    if not password:
        raise SystemExit("set WP_APP_PASSWORD (a WordPress Application Password) in the environment")
    wp = WP(args.url, args.user, password)
    wp.check_auth()
    if args.cmd == "export":
        export(wp, args.out)
    else:
        restore(wp, args.src, args.dry_run)


if __name__ == "__main__":
    sys.exit(main())
