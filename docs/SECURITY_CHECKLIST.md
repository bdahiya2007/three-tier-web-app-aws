# Security checklist

Every security issue found in this project's two security reviews (the first after the RDS read replica was added, the second a stack-wide pass), with its severity, the risk of leaving it unfixed, how it was fixed, and how the fix was verified **on the live stack** rather than assumed from a successful deploy.

Last updated: 2026-10-01. Detailed write-ups and full commands are in [Deployment.md](../Deployment.md) and [README.md](../README.md#security-review); this file is the one-page index.

## Severity scale

| Severity | Meaning here |
|---|---|
| **High** | Direct path to credential exposure, privilege escalation, or unauthenticated access to infrastructure |
| **Medium** | Weakens a security control (encryption, edge protection, least privilege, detection); exploitable only in combination with another weakness |
| **Low** | Defense in depth, hardening, or availability/resilience |

## Verification rule used throughout

A change is only marked fixed when the **real dependency** was tested directly: a real `mysql` login from an instance to both DB endpoints, a real phpredis connection, `iam simulate-principal-policy` against the live role, a real HTTP request through CloudFront. "The deploy succeeded" or "the site returns 200" is never accepted as proof — the Redis object cache can keep pages loading while the database rejects every connection (this actually happened once; see #11).

## Summary

| # | Issue | Severity | Status |
|---|---|---|---|
| 11 | DB master password leaked into CloudWatch Logs | High | ✅ Fixed, rotated, verified |
| 12 | CI deploy role could escalate itself to admin | High | ✅ Fixed, verified |
| 7 | SSH (port 22) open to the internet on the live stack | High | ✅ Fixed, verified |
| 13 | WAF bypass via someone else's CloudFront distribution | Medium | ✅ Fixed, verified |
| 3 | CloudFront → ALB traffic was plain HTTP | Medium | ✅ Fixed, verified |
| 5 | Merging to `main` deployed to AWS with no approval step | Medium | ✅ Fixed, verified |
| 8 | Redis: no encryption in transit/at rest, no AUTH | Medium | ✅ Fixed, verified |
| 16 | WordPress connected to RDS as the master user | Medium | ✅ Fixed, verified |
| 9 | No WAF logging | Medium | ✅ Fixed, verified |
| 14 | No brute-force protection; WordPress/PHP rule groups missing | Medium | ✅ Fixed, verified |
| 15 | WAF XSS exemption matched its path anywhere in the URL | Medium | ✅ Fixed, verified |
| 2 | No TLS between WordPress and RDS | Medium | 🟡 Stage 1 of 2 live; enforcement pending |
| 1 | RDS not encrypted at rest (primary + replica) | Medium | ⏸ Deferred (owner decision) |
| 6 | Template changes never reached running instances | Low | ✅ Fixed, verified |
| 10 | RDS deletion protection off / no Multi-AZ | Low | ✅ Deletion protection fixed; Multi-AZ accepted (cost) |
| — | `DBPassword` pattern allowed `'` and `\` (boot-breaking) | Low | ✅ Fixed |
| 17 | Hardening grab-bag (IMDSv2, HSTS, SHA pinning, …) | Low | 🟡 4 more items fixed (PR #41); 4 still open |
| 4 | Web servers in public subnets | Low | ⚪ Accepted (NAT Gateway cost) |

---

## High

### #11 — DB master password leaked into CloudWatch Logs — ✅ Fixed

- **Severity:** High
- **Found:** `UserData` ran under `bash -xe`; `-x` echoed the `sed` line that wrote the password into `wp-config.php` into `cloud-init-output.log`, which the CloudWatch agent ships to `/three-tier-app/cloud-init-output`. The password was also baked into every launch template version.
- **Risk if not fixed:** anyone with `logs:GetLogEvents`/`FilterLogEvents` on that log group — including the CI deploy role (`logs:*`) — could read the RDS master password in plaintext and get full control of the database.
- **Fix:**
  1. `set +x`/`set -x` around the credential lines so no new leaks (PR #21).
  2. Moved the password to Secrets Manager (`three-tier-app-db-master`), read at runtime by a 1-minute `refresh-db-secret` systemd timer into `/etc/wordpress/db-secret.php` (`root:apache`, mode `640`, outside the web root); removed from `UserData`/launch template entirely (PR #29).
  3. Treated the old password as exposed and rotated it to a generated value; deleted the `DBPassword` parameter and the `DB_PASSWORD` GitHub secret (PR #31).
- **Verification:**
  - Leak confirmed and later re-checked by *counting* matches, never printing them: `aws logs filter-log-events --log-group-name /three-tier-app/cloud-init-output --filter-pattern '"password_here"' --query 'length(events)'` → new instances log 0 password lines.
  - On instances: `refresh-db-secret.timer` active, `db-secret.php` is `-rw-r----- root apache`, `wp-config.php` contains only the `require` line.
  - **Lesson learned:** the first rotation was reported as verified from a 200 homepage, but RDS was actually on a different password than the secret; Redis masked it for ~45 minutes until a real login failed. Fixed RDS from the secret, then re-verified with a **direct `mysql` login to primary and replica** from an instance. That direct login is now the required check after any DB change.
- **Remaining:** optionally delete the 10 old log streams (or let 7-day retention expire them).

### #12 — CI deploy role could escalate itself to admin — ✅ Fixed

- **Severity:** High
- **Found:** the GitHub Actions deploy role lived in `vpc.yaml` and was allowed `iam:CreateRole`/`PutRolePolicy`/`AttachRolePolicy` on `role/three-tier-app-*` — a pattern matching its own name.
- **Risk if not fixed:** a compromised workflow run (or anyone able to get the role's credentials) could attach `AdministratorAccess` to the role or create a new role with any trust policy → full AWS account takeover.
- **Fix (structural, PRs #25, #26):** role moved to a separate, admin-deployed `pipeline.yaml` stack; explicit `Deny iam:*` on its own ARN; every role it creates or grants to must carry the `AppRoleBoundary` permissions boundary; `iam:DeleteRolePermissionsBoundary` explicitly denied. The AWS Backup service role (broad managed policy) also moved to the pipeline stack.
- **Verification:** `aws iam simulate-principal-policy` against the live role: modifying itself and removing a boundary → `explicitDeny`; creating a role without the boundary → `implicitDeny`. The first deploy's stuck rollback (CloudFormation couldn't *remove* the boundary) independently proved the deny works.

### #7 — SSH open to the internet on the live stack — ✅ Fixed

- **Severity:** High
- **Found:** `SSHLocationCidr` was still at its `0.0.0.0/0` default on the running stack, even though Deployment.md already told readers to restrict it.
- **Risk if not fixed:** port 22 on every web server reachable from anywhere — exposed to scanning, brute force, and any future OpenSSH vulnerability. Key-only auth mitigates but doesn't remove that.
- **Fix:** live parameter-only update setting `SSHLocationCidr` to a single `/32` (the IP is deliberately not recorded in this repo). Template default left as-is for anyone deploying from scratch.
- **Verification:** reviewed change set showed only `WebServerSecurityGroup` modified (no replacement); then confirmed directly against the security group that the rule's `CidrIp` actually changed.

---

## Medium

### #13 — WAF bypass via another CloudFront distribution — ✅ Fixed

- **Severity:** Medium
- **Found:** the ALB security group allows the AWS-managed CloudFront origin-facing prefix list, which covers *every* CloudFront distribution, not just this one.
- **Risk if not fixed:** an attacker creates their own distribution with this ALB as origin and reaches WordPress without passing through this stack's WAF (SQLi/XSS/rate-limit rules all skipped).
- **Fix (PRs #29, #30):** CloudFront sends a secret `X-Origin-Verify` header (48 random chars, from Secrets Manager); the ALB HTTPS listener forwards only when it matches (priority 1) and returns a fixed 403 for everything else (priority 2). Rolled out in two deploys — send first, enforce second — so CloudFront's own traffic was never rejected.
- **Verification:** `aws cloudfront get-distribution-config` confirmed the header was being sent before enforcement; `aws elbv2 describe-rules` shows forward-on-header at priority 1 and fixed 403 at priority 2; site returns 200 through CloudFront. Direct ALB access still times out (`curl ... http://<alb-dns>/` → `000`).

### #3 — CloudFront → ALB traffic was plain HTTP — ✅ Fixed

- **Severity:** Medium
- **Found:** `OriginProtocolPolicy: http-only`: viewer traffic encrypted to CloudFront, but the CloudFront → ALB hop was plaintext.
- **Risk if not fixed:** session cookies, login credentials and admin traffic cross the network unencrypted between CloudFront and the origin.
- **Fix (PR #18):** new HTTPS:443 ALB listener reusing the custom-domain ACM certificate; `OriginProtocolPolicy: https-only`; old HTTP listener and its security-group rule removed (also required by a 60-rule security-group quota — the 46-entry prefix list can't be referenced twice).
- **Verification:** site loads through CloudFront over the new origin path; live stack checked for zero drift from the template; ALB confirmed to have only the HTTPS listener.

### #5 — Merging to `main` deployed to AWS automatically — ✅ Fixed

- **Severity:** Medium
- **Found:** the merge was the only gate between a PR and a live AWS deploy.
- **Risk if not fixed:** an accidental or malicious merge goes straight to production with no last checkpoint.
- **Fix (PRs #15, #16):** `deploy` job targets a GitHub Environment `production` with a required reviewer (configured via the GitHub API). OIDC trust policy updated to accept the `environment:production` `sub` claim this introduced.
- **Verification:** next push to `main` paused at "Review deployments" until approved. The OIDC regression it caused was diagnosed from CloudTrail (`AssumeRoleWithWebIdentity` denied on the new `sub`), fixed, and the following deploy assumed the role successfully.

### #8 — Redis had no encryption or AUTH — ✅ Fixed

- **Severity:** Medium
- **Found:** ElastiCache `CacheCluster` with no TLS, no at-rest encryption, no AUTH token.
- **Risk if not fixed:** anything that reaches the cache's security group can read/poison cached WordPress data (options, sessions-adjacent transients) unauthenticated and in plaintext.
- **Fix (PR #37):** replaced with an `AWS::ElastiCache::ReplicationGroup` (`NumCacheClusters: 1`, `AutomaticFailoverEnabled: false` — `CacheCluster` doesn't support these properties) with `TransitEncryptionEnabled`, `AtRestEncryptionEnabled`, and an `AuthToken` from `RedisAuthSecret`, refreshed onto instances every minute; WordPress uses `WP_REDIS_SCHEME => 'tls'`.
- **Verification:** from an instance, using phpredis (WordPress's own client): TLS + correct token connects and `PING`s; wrong token → `WRONGPASS`; a plaintext command hangs instead of completing (encryption enforced at the protocol level); `wp_cache_set`/`wp_cache_get` round-trip real data.

### #16 — WordPress connected as the RDS master user — ✅ Fixed

- **Severity:** Medium
- **Found:** both HyperDB connections used `dbadmin` (the master user).
- **Risk if not fixed:** any WordPress compromise (malicious plugin, injection bug) inherits full DB admin: drop/alter tables, create users, read other databases.
- **Fix (PR #38):** dedicated `wordpress_app` user with `SELECT, INSERT, UPDATE, DELETE, CREATE TEMPORARY TABLES, LOCK TABLES` on the WordPress DB only; password in its own `DBAppUserSecret`; created idempotently at every boot; readiness healthcheck now tests this user.
- **Verification:** direct logins as `wordpress_app` to both endpoints: `SELECT` works; `GRANT`, `CREATE DATABASE`, `DROP`, `ALTER` all fail with `Access denied`. Then a full create → read → update → delete cycle through WordPress's own `wp_insert_post()`/`wp_update_post()`/`wp_delete_post()` to prove the grants are *sufficient*, not just restricted.

### #9 — No WAF logging — ✅ Fixed

- **Severity:** Medium
- **Found:** `aws wafv2 get-logging-configuration` → none; only sampled requests and metrics.
- **Risk if not fixed:** no way to investigate an attack after the fact or to tune rules safely.
- **Fix (PR #28):** `AWS::WAFv2::LoggingConfiguration` to the `aws-waf-logs-three-tier-app` log group, with `cookie` and `authorization` headers redacted.
- **Verification:** logging configuration present; live log records arrive (`aws logs tail aws-waf-logs-three-tier-app`) and show the redacted fields as redacted. These logs were later used to review the Count-mode rules (#14).

### #14 — No brute-force protection; WordPress/PHP rule groups missing — ✅ Fixed

- **Severity:** Medium
- **Found:** nothing limited requests to `wp-login.php`/`xmlrpc.php`; no WordPress, PHP, or known-bad-inputs managed rules.
- **Risk if not fixed:** credential stuffing/brute force against the admin login; known WordPress/PHP exploit patterns reach the app.
- **Fix:**
  - Per-IP rate-based rule on `wp-login.php`/`xmlrpc.php` (PR #28) — **live**.
  - `KnownBadInputs`, `WordPress`, `PHP` managed groups added in **Count** mode first (PR #28).
  - All three switched to Block (PR #41, deployed 2026-10-01) (`OverrideAction: None`) after a ~2-day log review: 618 requests, 8 matches, all scanner traffic (`/.env`, `/.aws/config`, `/xmlrpc.php`, `wlwmanifest.xml`), zero false positives on real traffic.
- **Verification:**
  - Rate limit: 130 requests to `/wp-login.php` → switched from 200 to WAF 403 after ~100.
  - Block switch: the same scanner paths found in the log review (`/.env`, `/.aws/config`, `//xmlrpc.php`, `//wp-includes/wlwmanifest.xml`) now return 403 on the live site, while the homepage still returns 200.

### #15 — WAF XSS exemption matched anywhere in the path — ✅ Fixed

- **Severity:** Medium
- **Found:** the REST-API XSS-body exemption used `CONTAINS "/wp-json/wp/v2/"`, so e.g. `/wp-comments-post.php/wp-json/wp/v2/x` would also skip the XSS check on an unauthenticated endpoint.
- **Risk if not fixed:** stored XSS payloads could be posted to the comments endpoint without WAF inspection.
- **Fix (PR #28):** `OrStatement` of two `STARTS_WITH` matches — `/wp-json/wp/v2/` and `/index.php/wp-json/wp/v2/` (this install uses plain permalinks; a single prefix would have broken every editor save).
- **Verification:** the old bypass path with an XSS body now returns 403; editor saves through `/index.php/wp-json/wp/v2/...` still succeed.

### #2 — No TLS between WordPress and RDS — 🟡 Stage 1 of 2 live

- **Severity:** Medium
- **Found:** WordPress ↔ RDS connections were unencrypted; the server didn't require TLS.
- **Risk if not fixed:** DB credentials and all query data travel in plaintext inside the VPC.
- **Fix:**
  - **Stage 1 (PR #40, live):** custom `DBParameterGroup` (`mysql8.4`) attached to both instances (in-place, confirmed no replacement via the change set); `MYSQL_CLIENT_FLAGS = MYSQLI_CLIENT_SSL` in `wp-config.php` so every HyperDB connection uses TLS.
  - **Stage 2 (not started):** `require_secure_transport = 1` (needs a reboot of both instances) **plus `--ssl` on the `UserData` healthcheck's `mysql` commands in the same deploy** — the mariadb CLI doesn't use TLS by default, so without it every future boot would fail its healthcheck.
- **Verification:**
  - Stage 1: `SHOW STATUS LIKE 'Ssl_cipher'` through WordPress's own `$wpdb` → `TLS_AES_256_GCM_SHA384` on the primary; same via `mysqli_real_connect(..., MYSQLI_CLIENT_SSL)` on the replica.
  - Stage 2 (planned): a plaintext `mysql` login (no `--ssl`) to both endpoints is **rejected**; `--ssl` login and WordPress still work; a new instance boots and signals success.

### #1 — RDS not encrypted at rest — ⏸ Deferred

- **Severity:** Medium
- **Found:** `StorageEncrypted: false` on primary and replica (`aws rds describe-db-instances --query "DBInstances[].[DBInstanceIdentifier,StorageEncrypted]"`).
- **Risk if not fixed:** snapshots and underlying storage hold blog data and user password hashes unencrypted; a mis-shared snapshot exposes everything. Mostly a compliance/defense-in-depth gap, since AWS controls the physical media.
- **Why deferred (owner decision, 2026-09-30):** fixing requires snapshot → encrypted copy → restore (new endpoint, real downtime), then recreating the replica from the encrypted primary. No ongoing cost difference.
- **Planned verification:** `StorageEncrypted: true` on both instances; direct `mysql` login to both new endpoints; WordPress read/write cycle.

---

## Low

### #6 — Template changes never reached running instances — ✅ Fixed

- **Severity:** Low
- **Risk if not fixed:** security fixes in `UserData`/AMI sat on the launch template while old, unpatched instances kept running until someone remembered a manual instance refresh.
- **Fix (PRs #14, #36):** `AutoScalingRollingUpdate` `UpdatePolicy`; later `WaitOnResourceSignals` + `cfn-signal` after a real DB login on both endpoints, with an `ERR` trap so a failed boot rolls the update back.
- **Verification:** live rolling update completed in 3m15s with SUCCESS signals from each new instance; stubbed tests of the readiness block for success, permanent DB failure (failure signal), and late-recovering DB.

### #10 — RDS deletion protection / Multi-AZ — ✅ Deletion protection fixed, Multi-AZ accepted

- **Severity:** Low
- **Risk if not fixed:** an accidental `delete-stack` or bad update could delete the primary DB (recoverable only from the daily backup); no automatic failover.
- **Fix (PR #28):** `DeletionProtection: true` on both instances. Multi-AZ not enabled — roughly doubles RDS cost.
- **Verification:** `aws rds describe-db-instances` → `DeletionProtection: True` on both.

### `DBPassword` allowed `'` and `\` — ✅ Fixed (first review)

- **Severity:** Low (availability)
- **Risk if not fixed:** `db-config.php` embeds the password in a single-quoted PHP string; a `'` would cause a fatal parse error on every boot — a self-inflicted outage on the next password change.
- **Fix:** `AllowedPattern` excluded `'` and `\`; the parameter has since been removed, and the generated Secrets Manager password excludes the same characters.
- **Verification:** generated password excludes those characters (`--exclude-characters "/@\"'\\ "`); instances boot and pass the DB-login readiness check.

### #17 — Hardening grab-bag — 🟡 Mostly fixed

| Item | Risk if not fixed | Status / fix | Verification |
|---|---|---|---|
| No explicit IMDSv2 | AMI default could change → SSRF could read instance-role credentials via IMDSv1 | ✅ Fixed (PR #41): `MetadataOptions: HttpTokens: required` | From a live instance: a token-less IMDS request gets `401`; a request with an IMDSv2 token still succeeds |
| No security headers (HSTS etc.) | Downgrade/clickjacking/MIME-sniffing exposure | ✅ Fixed (PR #41): CloudFront response headers policy (HSTS 30 days, no preload; `nosniff`; `SAMEORIGIN`; referrer policy) | `curl -I` on the live site shows all four headers |
| ALB logs bucket allows non-TLS access | Log data could be read/written over plaintext | ✅ Fixed (PR #41): `aws:SecureTransport: false` Deny in bucket policy | Deployed in PR #41. No separate live test recorded; AWS log delivery only uses TLS, so the Deny can't block it |
| GitHub Actions pinned by tag | A moved/compromised tag runs attacker code with deploy-role credentials | ✅ Fixed (PR #41): all actions pinned to full commit SHAs, tag kept as a comment | The deploy for PR #41 ran successfully on the pinned SHAs (checkout, configure-aws-credentials); `grep uses:` shows only SHAs |
| `DB_PASSWORD` interpolated into a `run:` step | Secret exposure via shell injection/logs | ✅ Gone (secret deleted, PR #31) | — |
| Instance readiness was a fixed pause | Broken boots went live | ✅ Fixed (see #6) | — |
| ALB → instance hop is plain HTTP | Plaintext inside the VPC | Open | — |
| WordPress/plugin downloads unpinned, no checksum | Supply-chain tampering at boot | Open | — |
| `chmod -R 755` on the web root | Overly broad file permissions (lower impact now that secrets live in `/etc/wordpress`, mode `640`) | Open | — |
| `terraform/` baseline: password in `user_data`, `0.0.0.0/0` ingress | Only matters if that baseline is deployed | Open (not deployed) | — |

### #4 — Web servers in public subnets — ⚪ Accepted

- **Severity:** Low
- **Risk:** instances have public IPs; exposure depends entirely on security groups (HTTP only from the ALB, SSH only from one `/32`).
- **Decision:** not fixing — a NAT Gateway costs ~$32.85/month + $0.045/GB, roughly doubling the stack's running cost.

---

## Out of scope

CloudTrail, GuardDuty and Security Hub are account-level services not defined in this stack's templates, so they weren't reviewed here.
