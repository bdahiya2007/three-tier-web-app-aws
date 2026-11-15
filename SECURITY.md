# Security policy

This is a personal portfolio project, not a supported product. Security reports are still welcome, and are handled on a best-effort basis.

## Reporting a vulnerability

Please report it **privately**, not in a public issue or pull request:

1. Open the repository's **Security** tab.
2. Choose **Report a vulnerability** (GitHub private vulnerability reporting).
3. Describe what you found, where, and how to reproduce it. Do not include real credentials or other people's data.

You can expect an acknowledgement within about a week and a fix or a decision as time allows. Please give me a reasonable chance to fix the
issue before sharing details publicly.

## What is in scope

- The CloudFormation in `cloudformation/`, the GitHub Actions workflows, the scripts in `scripts/` and the documentation: for example a way
  around the WAF or the ALB and security group rules, a weakness in the deploy role's trust policy, its permissions boundary or its
  self-modification denies, a way for the content backup workflow to write outside its branch, or a secret committed by mistake.

## What is out of scope

- Findings that need access to the owner's AWS or GitHub account.
- Weaknesses in AWS, GitHub or WordPress core themselves.
- The `terraform/` directory. It is an earlier, deliberately simpler baseline kept for comparison and is not deployed.
- The gaps already listed in the README's [Security review](README.md#security-review) section and in
  [docs/SECURITY_CHECKLIST.md](docs/SECURITY_CHECKLIST.md), which are known and tracked. This includes RDS storage that is not yet
  encrypted at rest and the web servers living in public subnets.
- Denial-of-service testing, load testing or any other testing against the deployed site. The deployed stack belongs to the owner and is
  not offered for testing; please review the code instead.

## Supported versions

Only the latest commit on `main` is maintained.

## A note on GitHub Actions permissions

"Allow GitHub Actions to create and approve pull requests" is enabled so that `content-backup.yml` can open its backup pull requests. This
is a single-maintainer repository and `main` does not require approving reviews, so the setting does not bypass any review gate. The
default `GITHUB_TOKEN` permission is read-only, and each workflow requests only the scopes it needs.

## If you find a secret

If you find what looks like a real credential in the repository or its history, report it privately as above. It will be rotated first,
then removed. Database and Redis credentials live in AWS Secrets Manager and are never committed.
