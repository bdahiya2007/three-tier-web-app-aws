# Deployment

Commands for deploying the full CloudFormation stack for the three-tier web app: a VPC spanning two Availability Zones, CloudFront (custom domain `blog.securecloudengineers.com`, DNS-validated ACM certificate, with a dedicated WAF Web ACL — SQLi and XSS managed rules) in front of an Application Load Balancer + Auto Scaling Group (2-3 instances by default, the ALB restricted to CloudFront's IP ranges only) launching WordPress EC2 instances (Amazon Linux 2023, PHP 8.3, Apache) across two public subnets, a MySQL RDS primary plus a read replica in the second AZ (WordPress routes writes to the primary and reads to the replica via the HyperDB drop-in), a single-node ElastiCache Redis cluster used as WordPress's object cache to reduce database load, an EFS file system mounted at `wp-content` on every instance so uploads/themes/plugins are shared across the group, a daily AWS Backup plan (30-day retention) covering RDS, EFS, and the EC2 web tier, a CloudWatch dashboard (EC2/RDS CPU, ALB request count), and logging (ALB access logs to S3, instance logs + RDS error log to CloudWatch Logs). Assumes AWS CLI v2 is installed and credentials are configured (`aws configure` or an active SSO/profile session) with permission to create VPC, RDS, EC2, ELBv2, EFS, ElastiCache, AWS Backup, IAM, S3, CloudWatch, CloudFront, WAF, ACM, Route 53, and Auto Scaling resources.

**Every `deploy` command below needs `--capabilities CAPABILITY_NAMED_IAM`** — the stack creates a named IAM role (`CloudWatchAgentRole`, for the CloudWatch agent on each instance), and CloudFormation refuses to create/update IAM resources without this explicit acknowledgment. Omitting it fails with `Requires capabilities : [CAPABILITY_NAMED_IAM]`.

The `DBPassword` parameter has no default and must be supplied at deploy time (8-41 characters, no `/`, `@`, `"`, `'`, `\`, or spaces — the last two are excluded specifically because `db-config.php`'s HyperDB setup embeds this value inside a single-quoted PHP string literal; an unescaped `'` would break that string and take the site down on the next instance boot).

If your account is on the RDS free tier, `DBBackupRetentionPeriod` must stay at its default (`1`) — a higher value fails with `The specified backup retention period exceeds the maximum available to free tier customers`.

`KeyPairName` also has no default and must reference an EC2 key pair that already exists in `us-east-1` (see "Create a key pair" below).

`SSHLocationCidr` defaults to `0.0.0.0/0` (open to the internet). Restrict it to your own IP for anything beyond a quick test, e.g. `--parameter-overrides SSHLocationCidr=$(curl -s ifconfig.me)/32 ...`. **A security review caught this exact gap on the live deployment** — the guidance already existed here, but the running stack had never actually had the override applied, leaving port 22 genuinely open. Fixed the same way: a live parameter-only update (no template change, since `0.0.0.0/0` stays the template's default for anyone else deploying this project from scratch), verified via a reviewed change-set showing only `WebServerSecurityGroup` modified (no replacement), then confirmed directly against the security group afterward that the rule's `CidrIp` actually changed. The IP itself is deliberately not written anywhere in this repo.

## Git workflow: branch, PR, merge — never push directly to `main`

All changes go through a feature branch and a pull request; nothing gets pushed or merged directly to `main`. Since `main` is what the GitHub Actions workflow deploys on every push, this gives every change a review point before it can reach live infrastructure. This is enforced by a branch protection rule on `main` (see "Branch protection on `main`" under "Automated deployment via GitHub Actions" below) — a direct push is rejected by GitHub itself, not just discouraged by convention.

```bash
git checkout main && git pull origin main
git checkout -b feature/<short-description>
# ... make changes, commit ...
git push -u origin feature/<short-description>
gh pr create --base main --head feature/<short-description> --title "..." --body "..."
```

Then merge the PR from GitHub's UI (or `gh pr merge <number>`) once it's reviewed — that merge is what triggers the actual deploy via CI.

**Keep feature branches short-lived.** If two branches sit open in parallel and both touch the same lines of `cloudformation/vpc.yaml`, merging the first one makes the second one conflict — an ordinary git conflict, not a CI problem (see "PR checks stop running / stuck pending" in Troubleshooting for the specific way this shows up with the `pull_request`-triggered lint job). Rebase onto the latest `main` before starting new work if another PR might land first, and merge promptly rather than letting several accumulate.

## Create a key pair

Skip this if you already have an EC2 key pair in `us-east-1`. Check with:

```bash
aws ec2 describe-key-pairs --region us-east-1 --query "KeyPairs[].KeyName" --output text
```

Otherwise, create one:

```bash
aws ec2 create-key-pair \
  --key-name three-tier-app-key \
  --region us-east-1 \
  --query "KeyMaterial" \
  --output text > three-tier-app-key.pem
chmod 400 three-tier-app-key.pem
```

AWS only returns the private key material once — save the `.pem` file somewhere safe. Use the key name (e.g. `three-tier-app-key`) as the `KeyPairName` value in the deploy commands below.

## Diagnosing a failed deploy

```bash
aws cloudformation describe-stack-events \
  --stack-name three-tier-app-network \
  --region us-east-1 \
  --query "StackEvents[?ResourceStatus=='CREATE_FAILED' || ResourceStatus=='UPDATE_FAILED'].[LogicalResourceId,ResourceStatus,ResourceStatusReason]" \
  --output table
```

A failed `deploy` on an already-existing stack typically leaves it in `UPDATE_ROLLBACK_COMPLETE`, not deleted — the previous good state is preserved. Fix the template/parameters and re-run the same `deploy` command; no need to delete the stack first. (A failed *initial* create instead leaves it in `ROLLBACK_COMPLETE`, which does need to be deleted before retrying.)

## Deploy the stack

There are two stacks, and **order matters**. Deploy the pipeline stack first (deploy role, Backup service role, permissions boundary). The app stack imports its exports and fails with `No export named three-tier-app-pipeline-... found` without it. See "Why the deploy role lives in its own stack" for why they're separate.

```bash
aws cloudformation deploy \
  --template-file cloudformation/pipeline.yaml \
  --stack-name three-tier-app-pipeline \
  --region us-east-1 \
  --capabilities CAPABILITY_NAMED_IAM \
  --parameter-overrides GitHubRepo=<your-repo-name> GitHubRepoId=<your-repo-id>
```

Then the app stack:

```bash
aws cloudformation deploy \
  --template-file cloudformation/vpc.yaml \
  --stack-name three-tier-app-network \
  --region us-east-1 \
  --capabilities CAPABILITY_NAMED_IAM \
  --parameter-overrides DBPassword=<your-db-password> KeyPairName=<your-key-pair-name>
```

`deploy` is idempotent — re-running it after editing the template updates the existing stack instead of failing. Since the launch template's `UserData` depends on the RDS endpoint, CloudFormation waits for the database to finish creating before the Auto Scaling Group launches any instances, so this can take 10-15 minutes.

### Deploy with a custom Auto Scaling Group size

`AsgMinSize` (default `2`), `AsgMaxSize` (default `3`), and `AsgDesiredCapacity` (default `2`) can also be overridden at deploy time:

```bash
aws cloudformation deploy \
  --template-file cloudformation/vpc.yaml \
  --stack-name three-tier-app-network \
  --region us-east-1 \
  --capabilities CAPABILITY_NAMED_IAM \
  --parameter-overrides AsgMinSize=2 AsgMaxSize=4 AsgDesiredCapacity=3 DBPassword=<your-db-password> KeyPairName=<your-key-pair-name>
```

### Deploy with a custom DB name and username

`DBName` (default `appdb`) and `DBUsername` (default `admin`) can also be overridden at deploy time:

```bash
aws cloudformation deploy \
  --template-file cloudformation/vpc.yaml \
  --stack-name three-tier-app-network \
  --region us-east-1 \
  --capabilities CAPABILITY_NAMED_IAM \
  --parameter-overrides DBName=myappdb DBUsername=myadmin DBPassword=<your-db-password> KeyPairName=<your-key-pair-name>
```

### Deploy with a custom DB size

`DBAllocatedStorage` (default `20` GiB) and `DBInstanceClass` (default `db.t3.micro`) can also be overridden at deploy time:

```bash
aws cloudformation deploy \
  --template-file cloudformation/vpc.yaml \
  --stack-name three-tier-app-network \
  --region us-east-1 \
  --capabilities CAPABILITY_NAMED_IAM \
  --parameter-overrides DBAllocatedStorage=50 DBInstanceClass=db.t3.small DBPassword=<your-db-password> KeyPairName=<your-key-pair-name>
```

## Review changes before applying (recommended for updates)

`aws cloudformation deploy` applies immediately with no confirmation prompt. For an update to an already-running stack — especially one that replaces or removes resources, like adding the ALB/ASG did to the previous single-instance setup — it's safer to create a change set first, review what it will actually do, then execute it:

```bash
aws cloudformation deploy \
  --template-file cloudformation/vpc.yaml \
  --stack-name three-tier-app-network \
  --region us-east-1 \
  --capabilities CAPABILITY_NAMED_IAM \
  --no-execute-changeset
```

This prints a change set ARN instead of applying anything. Review it:

```bash
aws cloudformation describe-change-set \
  --change-set-name <change-set-arn-from-above> \
  --region us-east-1 \
  --query "Changes[].ResourceChange.[Action,LogicalResourceId,ResourceType,Replacement]" \
  --output table
```

`Action` shows `Add`/`Modify`/`Remove` per resource, and `Replacement: True` flags a resource that will be deleted and recreated (not just updated in place) — worth double-checking before proceeding, since that can cause brief downtime for that resource. Parameters you don't pass with `--parameter-overrides` are automatically reused from the stack's current values, so you don't need to re-supply `DBPassword`/`KeyPairName` on every update.

Once it looks right, apply it:

```bash
aws cloudformation execute-change-set \
  --change-set-name <change-set-arn-from-above> \
  --region us-east-1
```

Then wait for it to finish:

```bash
aws cloudformation wait stack-update-complete \
  --stack-name three-tier-app-network \
  --region us-east-1
```

## Update running instances after a launch template change

Any change that affects the launch template — `DBPassword`, `LatestAmiId`, `WebServerInstanceType`, or editing the `UserData` script itself (e.g. the PHP version installed) — creates a **new launch template version** when you deploy.

**`WebServerAutoScalingGroup` now has an `UpdatePolicy` (`AutoScalingRollingUpdate`, `MinInstancesInService: AsgMinSize`, `MaxBatchSize: 1`), so this rollout now happens automatically as part of the stack update itself** — the `aws cloudformation deploy`/`update-stack` call doesn't return `UPDATE_COMPLETE` until every instance has actually been replaced and passed its health check. No separate manual step needed for the common case anymore.

**Tradeoff worth knowing**: this removes the manual pause that used to exist between "the stack update finished" and "running instances actually got the new config" — previously, a bad AMI/UserData change would sit harmlessly on the launch template until someone manually ran an instance refresh, giving a chance to catch it first. Now a bad change rolls out automatically on merge. The safety net that replaces the manual pause is CloudFormation's own rollback behavior: instances that fail their health check during the rolling update cause the *whole stack update* to fail and roll back (same as any other resource failure) — so a broken change won't succeed in replacing every instance silently, but it does mean the failure surfaces during the deploy itself rather than being caught before instances are ever touched.

**Manual instance refresh is still available** for the case where you want to force new instances *without* any actual launch-template property change (e.g. to pick up new OS-level packages that landed inside the same AMI ID, or as a routine restart) — `UpdatePolicy` only triggers on a real diff to the launch template, so a genuinely no-op deploy won't roll anything automatically:

```bash
aws autoscaling start-instance-refresh \
  --auto-scaling-group-name three-tier-app-asg \
  --region us-east-1 \
  --preferences '{"MinHealthyPercentage":50,"InstanceWarmup":180}'
```

This does a rolling replacement — keeping at least 50% of instances healthy throughout — rather than terminating everything at once. Watch it:

```bash
aws autoscaling describe-instance-refreshes \
  --auto-scaling-group-name three-tier-app-asg \
  --region us-east-1 \
  --query "InstanceRefreshes[0].[Status,PercentageComplete,StatusReason]" \
  --output table
```

If you need to stop one partway through (e.g. you spot it's replacing instances with a broken configuration):

```bash
aws autoscaling cancel-instance-refresh \
  --auto-scaling-group-name three-tier-app-asg \
  --region us-east-1
```

Then verify instances actually landed on the new launch template version, and that the ALB considers them healthy:

```bash
aws ec2 describe-launch-template-versions \
  --launch-template-name three-tier-app-wordpress-lt \
  --region us-east-1 \
  --query "LaunchTemplateVersions[].[VersionNumber,LaunchTemplateData.ImageId,CreateTime]" \
  --output table

TG_ARN=$(aws elbv2 describe-target-groups --names three-tier-app-tg --region us-east-1 --query "TargetGroups[0].TargetGroupArn" --output text)
aws elbv2 describe-target-health --target-group-arn "$TG_ARN" --region us-east-1 --query "TargetHealthDescriptions[].[Target.Id,TargetHealth.State,TargetHealth.Reason]" --output table
```

### Gotcha: `LatestAmiId` doesn't auto-update just by editing the template

`LatestAmiId` is an `AWS::SSM::Parameter::Value<AWS::EC2::Image::Id>` parameter. Once a stack has deployed once, that parameter's **resolved value is stored on the stack**. Editing the template's `Default:` field (e.g. switching it from the Amazon Linux 2 SSM path to the Amazon Linux 2023 one) has **no effect on an already-running stack**, because `aws cloudformation deploy` treats any parameter you don't explicitly pass in `--parameter-overrides` as "reuse previous value" — and it reuses the *original* SSM path from the first deploy, not your new default. The launch template will get a new version (if `UserData` also changed) with all-new script content, but still pointing at the old AMI — producing broken instances that fail health checks with something like a missing package manager.

To actually pick up a new default AMI, pass it explicitly at least once:

```bash
aws cloudformation deploy \
  --template-file cloudformation/vpc.yaml \
  --stack-name three-tier-app-network \
  --region us-east-1 \
  --capabilities CAPABILITY_NAMED_IAM \
  --parameter-overrides LatestAmiId=/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64 DBPassword=<your-db-password> KeyPairName=<your-key-pair-name>
```

After that, the value is stored on the stack and future deploys will keep reusing it (still frozen — the SSM path is only ever re-resolved to a literal AMI ID at the moment a `deploy` explicitly passes it as an override).

### Deploy restoring the database from a snapshot

`DBSnapshotIdentifier` (blank/empty by default, meaning a fresh empty database) restores RDS from an existing snapshot instead — useful after recreating a deleted stack. List available snapshots:

```bash
aws rds describe-db-snapshots \
  --region us-east-1 \
  --query "DBSnapshots[].[DBSnapshotIdentifier,DBInstanceIdentifier,Status,SnapshotCreateTime]" \
  --output table
```

Then deploy with it, making sure `DBName` and `DBUsername` **match the snapshot's original values** (RDS ignores/rejects mismatches here — see "Troubleshooting" below):

```bash
aws cloudformation deploy \
  --template-file cloudformation/vpc.yaml \
  --stack-name three-tier-app-network \
  --region us-east-1 \
  --capabilities CAPABILITY_NAMED_IAM \
  --parameter-overrides \
    DBSnapshotIdentifier=<snapshot-id> \
    DBName=<snapshot-original-db-name> \
    DBUsername=<snapshot-original-master-username> \
    DBPassword=<new-password-of-your-choice> \
    KeyPairName=<your-key-pair-name>
```

Immediately after `DBInstance` reaches `available` (RDS snapshots never store the master password, so it must be set explicitly post-restore):

```bash
aws rds modify-db-instance \
  --db-instance-identifier <db-instance-identifier> \
  --master-user-password '<same-value-as-DBPassword-above>' \
  --apply-immediately \
  --region us-east-1
```

## Scale down/up for cost control when idle

The Auto Scaling Group's `MinSize`/`DesiredCapacity` don't need to stay at their normal values (2) all the time — scale down to 1 instance when the site isn't actively being used, and back up to 2 when it is, to roughly halve the EC2 cost during idle periods.

**Always scale via `aws cloudformation deploy`, never via `aws autoscaling update-auto-scaling-group` directly.** This project has a GitHub Actions workflow that runs `aws cloudformation deploy` on every push to `main` (see "Automated deployment via GitHub Actions"). CloudFormation tracks `AsgMinSize`/`AsgDesiredCapacity` as stack parameters; if you scale the ASG directly via the Auto Scaling API instead of through a CloudFormation deploy, CloudFormation doesn't know about that change — the *next* deploy (including one triggered by an unrelated doc-only push) will detect the drift and silently reset the ASG back to whatever CloudFormation still has on record, undoing your scale-down without any warning.

**Scale down (idle, 1 instance):**

```bash
aws cloudformation deploy \
  --template-file cloudformation/vpc.yaml \
  --stack-name three-tier-app-network \
  --region us-east-1 \
  --capabilities CAPABILITY_NAMED_IAM \
  --parameter-overrides AsgMinSize=1 AsgDesiredCapacity=1
```

**Scale back up (active use, normal 2):**

```bash
aws cloudformation deploy \
  --template-file cloudformation/vpc.yaml \
  --stack-name three-tier-app-network \
  --region us-east-1 \
  --capabilities CAPABILITY_NAMED_IAM \
  --parameter-overrides AsgMinSize=2 AsgDesiredCapacity=2
```

Omitted parameters (`DBPassword`, `KeyPairName`, etc.) reuse their current stored values automatically — no need to re-supply them just to change the ASG size. `AsgMaxSize` (default `3`) is left alone either way, so the group can still burst up under load even while scaled down to a 1-instance floor.

Scaling down to 1 removes the multi-AZ redundancy that scaling to 2+ provides — acceptable for a deliberately idle period, not for normal operation. Scaling to `0` is also possible (maximum savings, but the ALB returns `503` to any visitor until scaled back up, and a scale-up from `0` means every instance is a cold boot — full `UserData` bootstrap, EFS mount, WordPress install — rather than most instances already being warm).

## Check stack status

```bash
aws cloudformation describe-stacks \
  --stack-name three-tier-app-network \
  --region us-east-1 \
  --query "Stacks[0].StackStatus"
```

## View stack outputs (VPC ID, subnet IDs, route table IDs, RDS endpoint, Redis endpoint, ALB DNS name, CloudFront domain, custom domain certificate ARN, WAF Web ACL ARN, EFS file system ID, backup vault/plan, CloudWatch dashboard URL, ALB logs bucket, log group names, WordPress URL)

```bash
aws cloudformation describe-stacks \
  --stack-name three-tier-app-network \
  --region us-east-1 \
  --query "Stacks[0].Outputs" \
  --output table
```

## View the CloudWatch dashboard

The stack creates a dashboard (`CloudWatchDashboard`) with three widgets:

- **EC2 CPUUtilization (Auto Scaling Group)** — average CPU across all instances in `WebServerAutoScalingGroup`, not per-instance. Individual instances come and go (scaling, health-check replacement, instance refresh), so this is deliberately aggregated at the ASG level rather than tied to specific instance IDs that won't exist for long.
- **RDS CPUUtilization** — average CPU for the `DBInstance`.
- **ALB RequestCount** — total requests per period hitting the `ApplicationLoadBalancer`, summed (not averaged) since it's a count, not a percentage.

All three use a 300-second (5 minute) period.

Get the direct console link from the stack output:

```bash
aws cloudformation describe-stacks \
  --stack-name three-tier-app-network \
  --region us-east-1 \
  --query "Stacks[0].Outputs[?OutputKey=='CloudWatchDashboardURL'].OutputValue" \
  --output text
```

Or fetch the dashboard body directly via the CLI (useful to confirm which physical resource IDs each widget is actually pointing at, e.g. after a stack recreation changes the ALB's ARN or the RDS instance identifier):

```bash
aws cloudwatch get-dashboard \
  --dashboard-name three-tier-app-dashboard \
  --region us-east-1 \
  --query "DashboardBody" \
  --output text | python3 -m json.tool
```

### Verify the dashboard actually has data (not just correct widgets)

A dashboard can be structurally valid — correct namespace, metric name, dimension — while still showing nothing, if the dimension values don't match anything real (e.g. a stale resource ID left over from before a stack recreation). Confirm actual data points exist for each metric:

```bash
END=$(date -u +%Y-%m-%dT%H:%M:%S)
START=$(date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%S)

aws cloudwatch get-metric-statistics --namespace AWS/EC2 --metric-name CPUUtilization \
  --dimensions Name=AutoScalingGroupName,Value=three-tier-app-asg \
  --start-time "$START" --end-time "$END" --period 300 --statistics Average \
  --region us-east-1 --query "Datapoints" --output table

aws cloudwatch get-metric-statistics --namespace AWS/RDS --metric-name CPUUtilization \
  --dimensions Name=DBInstanceIdentifier,Value=<db-instance-identifier> \
  --start-time "$START" --end-time "$END" --period 300 --statistics Average \
  --region us-east-1 --query "Datapoints" --output table

aws cloudwatch get-metric-statistics --namespace AWS/ApplicationELB --metric-name RequestCount \
  --dimensions Name=LoadBalancer,Value=<alb-arn-suffix, e.g. app/three-tier-app-alb/xxxxxxxx> \
  --start-time "$START" --end-time "$END" --period 300 --statistics Sum \
  --region us-east-1 --query "Datapoints" --output table
```

If any of these return an empty `Datapoints` list while the resource itself is healthy and receiving traffic, double check the dimension value against the resource's *current* identifier — see "The ALB gets a brand-new DNS name every time" and similar entries in Troubleshooting; the same "stale identifier after stack recreation" pattern applies to RDS instance identifiers and ALB ARNs, not just the WordPress URL.

## View logs

Three log sources are configured, landing in two different places:

| Source | Destination | Retention |
|---|---|---|
| ALB access logs (every request: client IP, path, status, target, latency) | S3 bucket (`ALBLogsBucket`) | `LogRetentionDays` (default 7) via S3 lifecycle rule |
| Each instance's Apache `error_log` | CloudWatch Logs, log group `/<EnvironmentName>/httpd-error` | `LogRetentionDays` (default 7) |
| Each instance's `cloud-init-output.log` (the `UserData` bootstrap script's full output — the same thing we've been reading over SSH all along) | CloudWatch Logs, log group `/<EnvironmentName>/cloud-init-output` | `LogRetentionDays` (default 7) |
| RDS error log | CloudWatch Logs, log group `/aws/rds/instance/<db-instance-identifier>/error` | `LogRetentionDays` (default 7), set via a Lambda-backed custom resource (`DBErrorLogRetention`) rather than a plain `AWS::Logs::LogGroup` — see "Why does the RDS error log group need a custom resource for retention?" in Troubleshooting for why. |

### The DB password used to leak into the cloud-init log

`UserData` runs under `#!/bin/bash -xe`, and `-x` echoes every command before running it — including the `sed` lines that write `DBName`/`DBUsername`/`DBPassword` into `wp-config.php`. Since `cloud-init-output.log` is shipped to CloudWatch Logs, **the DB master password was readable in plaintext by anyone with `logs:GetLogEvents`/`FilterLogEvents`** on that log group (which includes `GitHubActionsDeployRole`'s `logs:*`). Found during a security review by counting matches without printing them:

```bash
aws logs filter-log-events --log-group-name /<EnvironmentName>/cloud-init-output --region us-east-1 \
  --filter-pattern '"password_here"' --query 'length(events)' --output text
# any non-zero line = a leaked password line exists (output is per page, so several numbers may print)
```

Fixed by wrapping those `sed` lines in `set +x` / `set -x`. The `db-config.php` heredoc was never affected — `-x` traces the `cat` command but not the heredoc body. The fix only prevents *new* leaks: log events already written stay until their retention expires, so after deploying it, delete the old log streams and rotate `DBPassword` (it must be treated as exposed).

**Follow-up:** the password is no longer in `UserData` at all. Instances now read it from Secrets Manager at runtime; see "DB password in Secrets Manager" below. That closes the launch-template exposure for new launch template versions. Older versions still hold the old password until it's rotated, which is the next step.

### Change the retention period

All four sources share one parameter, `LogRetentionDays` (default `7`). To change it for all of them at once:

```bash
aws cloudformation deploy \
  --template-file cloudformation/vpc.yaml \
  --stack-name three-tier-app-network \
  --region us-east-1 \
  --capabilities CAPABILITY_NAMED_IAM \
  --parameter-overrides LogRetentionDays=14 DBPassword=<your-db-password> KeyPairName=<your-key-pair-name>
```

This is a lightweight, non-destructive update — none of the four retention settings live in the EC2 launch template or `UserData`, so **no instance refresh is needed** afterward (unlike most other changes in this project). What actually happens per source:

- **ALB access logs (S3)**: the bucket's lifecycle rule (`ExpirationInDays`) updates in place.
- **Apache error log / cloud-init output (CloudWatch Logs)**: `RetentionInDays` on `HttpdErrorLogGroup`/`CloudInitLogGroup` updates in place.
- **RDS error log (CloudWatch Logs)**: the `DBErrorLogRetention` custom resource receives an `Update` event, which the Lambda handles identically to `Create` — it just calls `put_retention_policy` again with the new value.

Valid values are CloudWatch Logs' fixed retention options (1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731, 1096, 1827, 2192, 2557, 2922, 3288, 3653, or 0 for never expire) — an arbitrary number like `10` will fail with an `InvalidParameterException` from the CloudWatch Logs API for the log-group-based sources (S3's `ExpirationInDays` for the ALB logs bucket, by contrast, accepts any positive integer).

To check the current effective value on each resource without guessing from the parameter alone (useful after any manual `put-retention-policy` intervention, which drifts from what's in the template until the next deploy):

```bash
aws s3api get-bucket-lifecycle-configuration --bucket <alb-logs-bucket-name> --region us-east-1
aws logs describe-log-groups --log-group-name-prefix /<EnvironmentName> --region us-east-1 --query "logGroups[].[logGroupName,retentionInDays]" --output table
aws logs describe-log-groups --log-group-name-prefix /aws/rds/instance --region us-east-1 --query "logGroups[].[logGroupName,retentionInDays]" --output table
```

### ALB access logs (S3)

```bash
aws s3 ls s3://<alb-logs-bucket-name>/alb-logs/AWSLogs/<account-id>/elasticloadbalancing/us-east-1/ --recursive
aws s3 cp s3://<alb-logs-bucket-name>/alb-logs/AWSLogs/<account-id>/elasticloadbalancing/us-east-1/<year>/<month>/<day>/<log-file>.log.gz - | gunzip
```

Get `<alb-logs-bucket-name>` from the `ALBLogsBucketName` stack output. Delivery isn't instant — allow a few minutes after a request for its log entry to actually land in S3.

### Instance logs (CloudWatch Logs)

```bash
# tail the Apache error log across all instances
aws logs tail /<EnvironmentName>/httpd-error --region us-east-1 --follow

# tail the bootstrap script output (equivalent to SSHing in and reading /var/log/cloud-init-output.log,
# but this survives even after the instance that produced it is terminated)
aws logs tail /<EnvironmentName>/cloud-init-output --region us-east-1 --follow
```

Each instance writes to its own log stream (named by instance ID) within these log groups, so `tail` interleaves output from every currently-running and recently-terminated instance.

### RDS error log

```bash
aws logs tail /aws/rds/instance/<db-instance-identifier>/error --region us-east-1 --follow
```

### Verify logging is actually working (not just deployed)

Same caution as everywhere else in this file — a "no errors during deploy" doesn't mean data is actually flowing. Confirmed working after the initial logging rollout via:

```bash
# 1. Confirm the CloudWatch agent actually created a log stream per instance (not just the log group existing)
aws logs describe-log-streams --log-group-name /<EnvironmentName>/httpd-error --region us-east-1 --query "logStreams[].[logStreamName,lastEventTimestamp]" --output table
aws logs describe-log-streams --log-group-name /<EnvironmentName>/cloud-init-output --region us-east-1 --query "logStreams[].[logStreamName,lastEventTimestamp]" --output table

# 2. Read actual content from a stream (stream name = instance ID)
aws logs get-log-events --log-group-name /<EnvironmentName>/cloud-init-output --log-stream-name <instance-id> --region us-east-1 --limit 5 --query "events[].message" --output text

# 3. Confirm ALB access log objects are actually landing in S3 (not just the bucket/policy existing)
aws s3 ls s3://<alb-logs-bucket-name>/alb-logs/ --recursive | tail -5

# 4. Confirm the RDS log group was actually created once the export was enabled
aws logs describe-log-groups --log-group-name-prefix /aws/rds/instance --region us-east-1 --query "logGroups[].[logGroupName,retentionInDays]" --output table
```

If step 1 shows no streams (empty result) after an instance has been running a few minutes, the CloudWatch agent isn't actually running — check `systemctl status amazon-cloudwatch-agent` on the instance and confirm the IAM instance profile (`CloudWatchAgentInstanceProfile`) is actually attached (`aws ec2 describe-instances --instance-ids <id> --query "Reservations[0].Instances[0].IamInstanceProfile"`). A stack update that adds/changes the launch template's `IamInstanceProfile` doesn't retroactively attach it to already-running instances — same as any other launch template change, an instance refresh is required (see "Update running instances after a launch template change").

## Access the WordPress site

Once the stack finishes and each instance's `UserData` script completes (allow a few extra minutes after `UPDATE_COMPLETE`/`CREATE_COMPLETE` for WordPress to install and the ALB target group health checks to pass), open the `WordPressURL` output value in a browser to run the WordPress setup wizard. `WordPressURL` is the **CloudFront** domain, not the ALB directly — see "CloudFront and WAF" below for why. CloudFront distribution changes also need extra time beyond the CloudFormation stack reaching `UPDATE_COMPLETE`/`CREATE_COMPLETE` (typically 5-15 more minutes) to actually propagate to edge locations worldwide; a `403`/timeout in the first few minutes after a fresh deploy doesn't necessarily mean something's wrong.

Since instances are now managed by an Auto Scaling Group, there's no single stable instance to SSH into. To reach a specific instance for troubleshooting, list the running instances and their public IPs first:

```bash
aws autoscaling describe-auto-scaling-groups \
  --auto-scaling-group-names three-tier-app-asg \
  --region us-east-1 \
  --query "AutoScalingGroups[0].Instances[].InstanceId" \
  --output text

aws ec2 describe-instances \
  --instance-ids <instance-id-from-above> \
  --region us-east-1 \
  --query "Reservations[0].Instances[0].PublicIpAddress" \
  --output text
```

```bash
ssh -i <your-key-pair-name>.pem ec2-user@<public-ip-from-above>
```

**Note on shared state**: each instance installs its own local copy of WordPress core files and connects to the same RDS database. `wp-content` (themes, plugins, and media uploads) is mounted from a shared EFS file system (`EFSFileSystem`), so content written there by any instance — media uploads, installed plugins/themes — is immediately visible on all instances. On first boot, an instance seeds EFS with the default `wp-content` from the WordPress tarball only if EFS is still empty, so this works correctly whether it's the very first instance ever or a replacement joining an existing group.

### Verify EFS sharing is actually working

Don't just trust that the mount succeeded at boot (check `/var/log/cloud-init-output.log` for that) — confirm files actually propagate between instances. Get two instance IPs first (see the ASG/IP commands above), then:

```bash
# From instance 1: write a marker file into the shared mount
ssh -i <your-key-pair-name>.pem ec2-user@<instance-1-public-ip> \
  "sudo -u apache bash -c 'echo hello-from-instance-1 > /var/www/html/wp-content/efs-share-test'"

# From instance 2: read it back
ssh -i <your-key-pair-name>.pem ec2-user@<instance-2-public-ip> \
  "cat /var/www/html/wp-content/efs-share-test"
```

If instance 2 prints `hello-from-instance-1`, the shared mount is working end-to-end (not just mounted, but actually propagating writes between instances in real time). Repeat in the opposite direction to confirm both ways, then clean up:

```bash
ssh -i <your-key-pair-name>.pem ec2-user@<instance-1-public-ip> \
  "sudo rm -f /var/www/html/wp-content/efs-share-test"
```

## CloudFront and WAF

CloudFront sits in front of the ALB as the actual public entry point, with a dedicated WAF Web ACL (`WAFWebACL`) attached — AWS managed rule groups `AWSManagedRulesSQLiRuleSet` (SQL injection) and `AWSManagedRulesCommonRuleSet` (includes `CrossSiteScripting_*` rules, among broader OWASP baseline coverage — verified via `aws wafv2 describe-managed-rule-group` rather than assumed from the rule group's name), plus one custom rule (`BlockXSSBodyExceptRestApi`) scoping the `CrossSiteScripting_BODY` rule's blocking away from the WordPress REST API — see "Editing WordPress content ... fails" in Troubleshooting for why.

**Cost added**: WAF has a flat ~$5/month Web ACL fee plus ~$1/month per rule group (2 here, ~$7/month total) plus a small per-million-requests charge; CloudFront itself is likely near-free at this project's traffic level (within or close to its own free tier for data transfer/requests). Brings the running total from the earlier ~$50-54/month estimate to roughly **$57-61/month**.

**Added later (second security review):**
- **`RateLimitLoginAndXmlRpc`** (Block): more than 100 requests per IP in 5 minutes to `/wp-login.php` or `/xmlrpc.php` is blocked. It's scoped to those two paths so normal browsing (and CloudFront-cached traffic) is never counted toward it.
- **`AWSManagedRulesKnownBadInputsRuleSet`, `AWSManagedRulesWordPressRuleSet`, `AWSManagedRulesPHPRuleSet`**, all in **Count** mode (`OverrideAction: Count`). The earlier `SizeRestrictions_BODY` and `CrossSiteScripting_BODY` false positives showed that managed rules can break real WordPress traffic. So these first run in Count mode: check the WAF logs for matches on legitimate requests, then switch each one to `OverrideAction: None` (Block). See "WAF logs and promoting Count rules to Block" below.
- **WAF logging** to CloudWatch Logs, in log group `aws-waf-logs-<EnvironmentName>`. WAF requires the `aws-waf-logs-` prefix, and `us-east-1` for a CloudFront-scoped ACL. `cookie` and `authorization` headers are redacted, since WordPress auth cookies would otherwise be logged in full. Retention is `LogRetentionDays`.
- **Capacity**: 1,321 of the 1,500 WCU a web ACL allows, checked with `aws wafv2 check-capacity` before deploying.
- **Cost**: about +$4/month (three more rule groups plus one rule at ~$1 each), plus CloudWatch Logs ingestion for the WAF logs (vended-log pricing, pennies at this traffic).

### Custom domain (`blog.securecloudengineers.com`)

`CustomDomainCertificate` is a DNS-validated ACM certificate for `CustomDomainName` (`blog.securecloudengineers.com` by default), created in `us-east-1` — a hard CloudFront requirement, regardless of which region the rest of the stack lives in. `DomainValidationOptions` with `HostedZoneId` lets CloudFormation create the validation CNAME itself and wait for issuance as part of the stack update; no manual console step, and no leftover validation record after a delete.

`Route53HostedZoneId` (default `Z06930743HC9RLGHJO306`) points at the existing hosted zone for `securecloudengineers.com`, owned by a separate, independent stack (the `secure-static-website-aws` project, which already serves `www.securecloudengineers.com` from it). `CustomDomainDNSRecord`/`CustomDomainDNSRecordIPv6` add one new A/AAAA alias record into that zone for `blog.securecloudengineers.com` — a *new* record, not a modification of any of the zone's existing ones, so this doesn't have the cross-stack "whole list is authoritative" conflict that ruled out reusing that project's WAF Web ACL (see below): each `AWS::Route53::RecordSet` is its own independent resource, not a single list-valued property shared by every record in the zone.

The distribution's `Aliases` and `ViewerCertificate` were updated to use this certificate instead of the CloudFront default (`*.cloudfront.net`) certificate — `WordPressURL` now points at the custom domain, and the default CloudFront domain (`CloudFrontDomainName` output) still works too, side by side.

**After deploying**: same `wp_options` fix as below, but using the custom domain now, not the CloudFront domain — `siteurl`/`home` need to match whatever URL is actually being used to reach the site, or WordPress redirects to a stale one.

### Why not reuse the existing WAF Web ACL from the other portfolio project

This account already has a Web ACL (`securecloudengineers-waf`) from the `secure-static-website-aws` repo. Deliberately not reused here:
- It only has the SQLi rule set — no XSS coverage, so reusing it as-is wouldn't fully satisfy the requirement.
- It's owned and managed by an **independent CloudFormation stack**. A resource can only be "owned" by one stack; referencing/importing it into this template would mean two unrelated stacks fighting over its `Rules` list on every future update — CloudFormation treats `Rules` as the complete authoritative list, so an update to either stack would silently overwrite whatever the other one expects.
- Adding the missing XSS rule to it via a one-off AWS CLI call (bypassing CloudFormation) would work briefly, then get silently reverted the next time that *other* project's stack does any unrelated update.
- Sharing one Web ACL couples two otherwise-independent projects' security posture and mixes their WAF metrics/logs together.

This template creates its own dedicated `WAFWebACL`, scoped only to this project's CloudFront distribution.

### Why the ALB is now locked down to CloudFront's IP ranges only

`ALBSecurityGroupIngressHttpsFromCloudFront` restricts the ALB's security group to the AWS-managed prefix list `com.amazonaws.global.cloudfront.origin-facing` (`CloudFrontOriginFacingPrefixListId`, default `pl-3b927c52`) instead of `0.0.0.0/0`. Without this, the WAF protection would be purely cosmetic — anyone could bypass CloudFront (and its WAF) entirely by hitting the ALB's DNS name directly. This is a real, load-bearing part of "attach a WAF," not an optional hardening extra.

**Consequence**: the ALB's DNS name (`LoadBalancerDNSName` output) is no longer reachable from your laptop directly — only from CloudFront's edge network. Every `curl http://<alb-dns-name>` example used earlier in this file (and throughout this project's troubleshooting history) now only works from *inside* an EC2 instance in the VPC, not from an external machine, and only over HTTPS now (see below) — not HTTP at all. Use `WordPressURL` (the CloudFront domain) for anything from outside the VPC now.

### CloudFront-to-ALB traffic is now HTTPS, not plain HTTP

Previously, CloudFront terminated TLS for viewers but talked to the ALB over plain HTTP (`OriginProtocolPolicy: http-only`) — visitor traffic was encrypted end-to-end to CloudFront, but the CloudFront-to-origin hop inside AWS's network was not. Fixed by:
- `ALBHttpsListener`: a new HTTPS:443 listener on the ALB, reusing the existing `CustomDomainCertificate` (no new certificate needed — ACM certs can be attached to multiple resources, and this one's already issued for the same account/region CloudFront needs)
- `CloudFrontDistribution`'s `CustomOriginConfig.OriginProtocolPolicy` changed to `https-only`
- The old HTTP:80 listener (`ALBListener`) and its security-group rule (`ALBSecurityGroupIngressFromCloudFront`) were **removed entirely**, not converted to an HTTP→HTTPS redirect — see the gotcha below for why a redirect listener wasn't an option here

**A real AWS quota hit while implementing this, not just a design choice**: the `com.amazonaws.global.cloudfront.origin-facing` prefix list currently has 46 entries, and each security-group rule referencing a prefix list consumes one rule slot *per entry in the list*, against a default quota of 60 rules per security group. Two separate CloudFront-facing rules (port 80 *and* port 443, each expanding to 46 slots) would need 92 slots — over the limit. Removing the HTTP rule entirely (rather than keeping both, or converting it to a redirect) was necessary, not just tidy — and it's harmless anyway, since CloudFront's origin is `https-only` now, so nothing will ever send it a port-80 request regardless of what the security group allows.

**Gotcha actually hit during rollout**: even with a template that correctly ends up with only the HTTPS rule, CloudFormation's default behavior when swapping one `AWS::EC2::SecurityGroupIngress` resource for another is to **create the new one before deleting the old one** — meaning it briefly needs both rules to exist simultaneously (92 slots) even though neither the starting nor ending state ever needs more than 46. This failed with `ServiceLimitExceeded` on a stack update that should have succeeded. Worked around by manually revoking the old port-80 rule first (`aws ec2 revoke-security-group-ingress`), which dropped the security group to 0 CloudFront-facing rules, then re-running the deploy — at which point adding the 46-entry HTTPS rule no longer had anything to collide with. This produces a brief (order of a minute or two) window where the ALB has no valid inbound path from CloudFront at all — a real, if short, planned outage, not something CloudFormation could avoid on its own given the quota.

### Why caching is disabled

`DefaultCacheBehavior` uses the AWS managed `CachingDisabled` policy plus the `AllViewerAndCloudFrontHeaders-2022-06` origin request policy (forwards all headers/cookies/query strings to the origin, plus CloudFront's own `CloudFront-*` headers — see below for why that second part matters). WordPress is a dynamic, session-aware application — caching GET responses at the edge risks serving one visitor's logged-in or nonce-specific page to another visitor entirely. This makes CloudFront function purely as a TLS-termination + WAF-enforcement layer for now, not a performance cache. Adding real caching for genuinely static paths (e.g. `/wp-content/uploads/*`) via a path-based cache behavior would be a sensible next step, out of scope for just adding WAF protection.

### Why the origin request policy forwards `CloudFront-*` headers (avoiding an infinite `/wp-admin` redirect)

The ALB origin is HTTP-only (`OriginProtocolPolicy: http-only` — there's no ALB HTTPS listener/certificate in this template), so CloudFront always talks to the ALB over plain HTTP even though the viewer's request came in over HTTPS. The ALB, in turn, adds its own `X-Forwarded-Proto` header reflecting *its own* listener protocol — which is `http` — not what the viewer actually used. WordPress (with `siteurl`/`home` set to the `https://` CloudFront domain) sees a plain-HTTP request, decides the URL scheme is wrong, and redirects `/wp-admin` to itself — forever, since every retry looks exactly like the first request.

The fix isn't in `X-Forwarded-Proto` at all — it's `CloudFront-Forwarded-Proto`, a header CloudFront itself adds that reflects the *viewer's* real protocol, not the CloudFront-to-origin hop. CloudFront only forwards its `CloudFront-*` headers to the origin when the origin request policy explicitly includes them, which is why this template uses `AllViewerAndCloudFrontHeaders-2022-06` instead of plain `AllViewer`. `wp-config.php`'s generated UserData then does:

```php
if ( isset( $_SERVER['HTTP_CLOUDFRONT_FORWARDED_PROTO'] ) && $_SERVER['HTTP_CLOUDFRONT_FORWARDED_PROTO'] === 'https' ) {
	$_SERVER['HTTPS'] = 'on';
}
```

inserted right after the "Add any custom values" marker in `wp-config.php`, so WordPress's own `is_ssl()` check reports correctly and stops redirecting. See "`/wp-admin` redirects to itself forever" in Troubleshooting for the exact symptom and how this was diagnosed.

### After deploying: fix `wp_options` again

Same issue as every previous change to the public entry point (see "WordPress login/internal links go to a dead URL" in Troubleshooting) — WordPress's `siteurl`/`home` database values still point at whatever URL was used during the last setup/fix, which is now stale. Update them the same way as before, using the current `WordPressURL` output value (the custom domain now, once that's set up — see above):

```sql
UPDATE wp_options SET option_value="<current-WordPressURL-output>" WHERE option_name IN ("siteurl","home");
```

**Since the Redis object cache was added, also flush it after this SQL update** — see "Direct SQL writes to `wp_options` no longer take effect on their own" under "Redis object cache" above for why and the exact command.

### WAF logs and promoting Count rules to Block

```bash
# live tail (one JSON record per request; terminatingRuleId shows what decided it)
aws logs tail aws-waf-logs-<EnvironmentName> --region us-east-1 --follow

# which Count-mode rules matched what, over the last 7 days (Logs Insights)
q=$(aws logs start-query --region us-east-1 --log-group-name aws-waf-logs-<EnvironmentName> \
  --start-time $(date -d '7 days ago' +%s) --end-time $(date +%s) \
  --query-string 'fields @timestamp, httpRequest.uri, httpRequest.clientIp
    | filter ispresent(nonTerminatingMatchingRules.0.ruleId)
    | stats count(*) by nonTerminatingMatchingRules.0.ruleId, httpRequest.uri
    | sort count(*) desc' --query queryId --output text)
sleep 10; aws logs get-query-results --region us-east-1 --query-id "$q"
```

When the Count-mode rule groups only match obvious attack traffic (scanners, `/.env`, `/wp-config.php.bak` and similar), change that group's `OverrideAction` from `Count: {}` to `None: {}` in the template. That's a normal PR, and the change is non-disruptive. If one specific rule inside a group hits legitimate requests, override just that rule to `Count` with `RuleActionOverrides` (the same pattern as `SizeRestrictions_BODY`) instead of leaving the whole group in Count.

Test the rate limit (it should switch from WordPress's own `200` to WAF's `403` after about 100 requests, within a minute or two; WAF rate-based rules aggregate with some delay):

```bash
for i in $(seq 1 130); do curl -s -o /dev/null -w "%{http_code}\n" https://<domain>/wp-login.php; done | sort | uniq -c
```

### Verify the WAF is actually blocking attacks (not just attached)

Same principle as everywhere else in this file — attached and configured isn't the same as actually working. Send requests that AWS's managed rule groups are documented to match, and confirm they're blocked (`403`), while a normal request still succeeds:

```bash
# Normal request - should succeed (200)
curl -s -o /dev/null -w "Normal request: %{http_code}\n" "https://<cloudfront-domain>/"

# SQL injection pattern in a query string - should be blocked (403) by AWSManagedRulesSQLiRuleSet
curl -s -o /dev/null -w "SQLi pattern: %{http_code}\n" "https://<cloudfront-domain>/?id=1' OR '1'='1"

# XSS pattern in a query string - should be blocked (403) by AWSManagedRulesCommonRuleSet's CrossSiteScripting_QUERYARGUMENTS rule
curl -s -o /dev/null -w "XSS pattern: %{http_code}\n" "https://<cloudfront-domain>/?q=<script>alert(1)</script>"
```

If the SQLi/XSS requests return `200` instead of `403`, the rules aren't actually active — check `aws wafv2 get-web-acl` for the current rule list and `aws cloudwatch get-metric-statistics` against the `${EnvironmentName}-waf-sqli`/`${EnvironmentName}-waf-common` metrics (from each rule's `VisibilityConfig`) to confirm the rule groups are receiving and evaluating traffic at all.

### Publishing a WordPress post fails with "Updating failed"

- **Symptom**: Saving/publishing a post of any real length (roughly 9 KB+) fails in the block editor with a generic "Updating failed" error. Short posts save fine; the exact size where it starts failing is consistent and repeatable.
- **Cause**: `AWSManagedRulesCommonRuleSet`'s `SizeRestrictions_BODY` rule blocks any request body over a hardcoded 8 KB — a heuristic against oversized/buffer-overflow-style payloads (from ModSecurity's Core Rule Set, which this managed rule group is based on), not a content-based attack signature. It has no configurable threshold, so it can't distinguish a long blog post's `wp-json/wp/v2/posts` REST API body from an actual attack — both just look like "a request body over 8 KB" to this one rule.
- **Fix**: two parts together, both on `WAFWebACL` (see "Custom domain" — same resource, no new one added):
  1. `RuleActionOverrides` on the `AWS-AWSManagedRulesCommonRuleSet` statement, overriding `SizeRestrictions_BODY`'s action to `Count` instead of the rule group's default `Block`. This doesn't disable the rule — it still evaluates and still shows up in the `${EnvironmentName}-waf-common` metric/sampled requests, just without blocking.
  2. `AssociationConfig.RequestBody.CLOUDFRONT.DefaultSizeInspectionLimit: KB_64` on the Web ACL itself, raising WAF's own request-body inspection window from the 8 KB default to 64 KB. This is the part that actually matters for security here: without it, the SQLi/XSS rules in the same rule group would only ever see the *first* 8 KB of any body, silently missing anything injected further in — since (1) alone lets larger bodies through, (2) makes sure they're still fully scanned once they are.
- **How this was actually verified, not just deployed**: `aws wafv2 get-sampled-requests` against the `three-tier-app-waf-common` metric, filtered to `SizeRestrictions_BODY`, showed real production autosave/`wp-json` requests transitioning from `BLOCK` to `COUNT` at the exact moment the stack update completed — not just synthetic test requests. Separately, a POST with a SQL injection payload appended after 12 KB of padding (past the *old* 8 KB window) still returned `403`, confirming the increased inspection limit actually extends detection rather than just permitting larger unscanned bodies.
- **Why this doesn't weaken the WAF's actual protection**: `SizeRestrictions_BODY` has no awareness of request *content* — overriding it doesn't touch the SQLi rule set or the XSS/RFI/LFI rules inside the Common Rule Set, which keep blocking exactly as before (and now see more of each request, not less). `Count` keeps it observable rather than silently disabling it, and 64 KB is still a real ceiling backed by the origin's own `post_max_size` limit underneath.
- **Cost**: none. The body inspection size setting isn't a separately-metered capability (unlike Bot Control) and doesn't consume additional Web ACL Capacity Units — WAF's pricing here is unchanged (still the Web ACL + per-rule-group + per-million-requests charges from the cost note above).

### Editing WordPress content (post body, template parts, the site editor) fails with a generic error, or CloudFront returns 403

- **Symptom**: Saving a post, editing a template part (e.g. the footer in Appearance → Editor), or any other content edit that goes through `wp-json/wp/v2/*` fails. Unlike the size-limit issue above, this isn't tied to content length — even a small (~3 KB) edit fails if the content happens to include things like `style="..."` attributes, which the block editor's own generated markup routinely does.
- **Cause**: `AWSManagedRulesCommonRuleSet`'s `CrossSiteScripting_BODY` rule flags request bodies containing patterns that look like XSS payloads. Inline `style` attributes (and similar HTML constructs the block editor legitimately produces) can trip this same heuristic — it has no way to distinguish WordPress's own generated markup from an actual injected `<script>` tag, so it blocks both identically.
- **Fix**: same two-part pattern as `SizeRestrictions_BODY`, but scoped more precisely since disabling XSS-body detection entirely would be a real reduction in protection (unlike the size rule, which had no content-safety role to begin with):
  1. `RuleActionOverrides` adds `CrossSiteScripting_BODY` → `Count` on the same `AWS-AWSManagedRulesCommonRuleSet` statement. The rule still evaluates and still applies its label — it just stops blocking on its own.
  2. A new custom rule, `BlockXSSBodyExceptRestApi` (priority 2, evaluated after both managed rule groups), re-blocks anything carrying the `awswaf:managed:aws:core-rule-set:CrossSiteScripting_Body` label **except** requests whose URI path starts with `/wp-json/wp/v2/` or `/index.php/wp-json/wp/v2/` (originally "contains"; see below) — the WordPress REST API path used for all content edits (posts, template parts, media). Everywhere else on the site, an XSS-body match is still blocked exactly as before.
- **How this was actually verified**: confirmed via `aws wafv2 get-sampled-requests` that `CrossSiteScripting_BODY` really was the rule firing on real production traffic (`/wp-json/wp/v2/posts/7/autosaves`, `/wp-json/wp/v2/template-parts/twentytwentyfive//footer` — the exact footer edit that prompted this fix) before changing anything. After deploying, sent the same style-attribute payload to both a REST API path (no longer blocked — reaches WordPress, confirmed by a `401` from WordPress itself, not a WAF `403`) and to `/wp-login.php` (still blocked, `403`, confirmed as a hit on the new `BlockXSSBodyExceptRestApi` rule specifically via its own metric) — proving the exception is scoped correctly, not a blanket bypass.
- **Why the REST API match is two exact prefixes, not `CONTAINS "/wp-json/wp/v2/"`**: it originally used `CONTAINS`, so the exception kept working under either permalink style. This install uses "plain" permalinks, so REST requests are `/index.php/wp-json/wp/v2/...` (confirm with `curl -sI https://<domain>/ | grep -i '^link:'`, which shows the REST root). A later security review found `CONTAINS` too loose: the substring can appear *anywhere* in the path, so `/wp-comments-post.php/wp-json/wp/v2/x` would also match and skip the XSS block for an unauthenticated endpoint (not exploit-tested, but no reason to leave it). It's now an `OrStatement` of two `STARTS_WITH` matches: `/wp-json/wp/v2/` (pretty permalinks) and `/index.php/wp-json/wp/v2/` (plain permalinks, in use). A single `STARTS_WITH "/wp-json/wp/v2/"` would have broken every editor save on this site. This entry is what caught that before it shipped.
- **Why this doesn't weaken the WAF's actual protection everywhere else**: the exception is scoped to one specific, narrow path prefix used only for authenticated content management — an actual XSS payload sent to any other endpoint (comment forms, contact forms, arbitrary query strings) is still blocked exactly as before. Unauthenticated requests to the REST API paths still get rejected by WordPress itself (`401`/`403` from WordPress, not from WAF) — the WAF exception only means WordPress's own auth/permission checks are what stand between an attacker and that endpoint now, same as they always were for any legitimate logged-in action.

### RDS bill has an unexpected "Extended Support" charge for MySQL 8.0

- **Symptom**: AWS Billing's "Cost breakdown" chart shows a disproportionately large RDS charge relative to how new/small the database actually is — e.g. two just-created `db.t3.micro` instances showing a combined charge well above what plain instance-hour + storage pricing would produce for that little runtime.
- **Cause**: MySQL 8.0 has exited AWS/Oracle's standard support window entirely. Once that happens, RDS bills a separate **Extended Support** surcharge per vCPU-hour (`ExtendedSupport:Yr1-Yr2:MySQL8.0` usage type, ~$0.10/vCPU-hour for Year 1-2, doubling to ~$0.20/vCPU-hour in Year 3+) on top of normal instance pricing — for *every* running hour, on *every* instance running that major version, regardless of how new, small, or lightly used the database is. It's not a one-time or usage-based charge; it accrues continuously until the engine is upgraded off 8.0.
- **How this was actually diagnosed**: `aws ce get-cost-and-usage` filtered to the RDS service returned near-zero for the whole account — a red flag on its own, since it didn't match the real, non-trivial total shown in the Billing console's "Cost summary" widget. That mismatch turned out to be a separate, real gotcha (see below), not evidence the RDS charge wasn't real. Checking the account's actual deployed engine version (`8.0.46`) and cross-referencing AWS's published Extended Support Year 1-2 rate against the account's tracked `ExtendedSupport:Yr1-Yr2:MySQL8.0` vCPU-hours accounted for essentially the entire unexplained charge.
- **Fix**: upgrade to a MySQL version still in standard support — 8.4 (the current LTS line) has no Extended Support SKU at all. In this template: set `DBEngineVersion` to `'8.4'` and add `AllowMajorVersionUpgrade: true` to `DBInstance`.
- **The read replica needs the same treatment, explicitly, and RDS enforces an update order CloudFormation can't express in one stack update**: a `DBInstance` update that only changes its own `EngineVersion` fails with `One or more of the DB Instance's read replicas need to be upgraded: <replica-id>` if a replica is still on the old major version. The natural fix — also setting `EngineVersion`/`AllowMajorVersionUpgrade` on `DBReadReplica` — doesn't fully solve it either, because `DBReadReplica`'s `SourceDBInstanceIdentifier` makes it *depend on* `DBInstance` in CloudFormation's graph, so CFN always tries to update the primary first, hitting the same guard rail every time. RDS's own requirement is the opposite order: **the replica must reach the target version before the primary does**, and CloudFormation has no way to express "update the dependent resource before the resource it depends on" here. The actual fix: upgrade the replica directly first, out-of-band (`aws rds modify-db-instance --db-instance-identifier <replica-id> --engine-version 8.4 --allow-major-version-upgrade --apply-immediately`), wait for it to reach `available`, *then* deploy the stack update for the primary — which then succeeds since the replica already satisfies RDS's requirement. The template still declares `EngineVersion`/`AllowMajorVersionUpgrade` on both resources (so future deploys/replacements get it correctly and there's no permanent drift from the template's declared state), it's specifically the *upgrade sequencing* that has to happen outside CloudFormation.
- **How this was actually verified, not just deployed**: after both instances reported `available`, connected directly and ran `SELECT VERSION()` against both (`8.4.9`), confirmed the replica's `read_only=ON` fail-safe survived the upgrade, confirmed a direct write to the replica still correctly fails with the same `ERROR 1290` as before, and confirmed `Com_select` on the replica was still climbing (real read traffic still routing there) — the same verification standard as the original HyperDB setup, re-run after a major infrastructure change instead of assumed to still hold.
- **Separate gotcha surfaced along the way: Cost Explorer's API (`aws ce get-cost-and-usage`) returned near-zero data for the entire account**, while the Billing console's "Cost summary"/"Cost breakdown" widgets showed real, accurate figures for the same period. These are different AWS systems — Cost Explorer requires an explicit one-time enable and can take up to 24 hours to backfill data even after that, while the classic Billing dashboard is always-on. On a newer account, don't trust an empty/zero Cost Explorer API response as "no cost" — cross-check against the Billing console directly.
- **Correction, found later: on this account the near-zero numbers were credits, not missing data.** The account is on AWS's **Free plan** (`aws freetier get-account-plan-state` → `accountPlanType: FREE`, with a remaining credit balance and an expiry date). Free-plan credits are applied as `Credit` line items that cancel out each service's usage, so a per-service `UnblendedCost` grouping sums to ~$0 even while real usage accrues. The real usage only appears when you filter out credits:
  ```bash
  aws ce get-cost-and-usage --time-period Start=2026-09-01,End=2026-09-29 --granularity MONTHLY \
    --metrics UnblendedCost --group-by Type=DIMENSION,Key=SERVICE \
    --filter '{"Dimensions":{"Key":"RECORD_TYPE","Values":["Usage"]}}'
  ```
  Measured this way: September's usage was **$23.22**, of which **$14.18 (61%) was `ExtendedSupport:Yr1-Yr2:MySQL8.0`**, peaking around **$9/day**. It dropped to ~$0 right after the 8.4 upgrade. Without Extended Support, the full stack runs at roughly $2–3/day of credits. **When Free plan credits run out (or the plan's 6 months end), AWS requires upgrading to a paid plan or the account is closed**, so watch the remaining balance, not just the bill. Each Cost Explorer API call costs $0.01.

### Verify direct ALB access is actually blocked (the bypass is actually closed)

```bash
curl -s -o /dev/null -w "Direct ALB access: %{http_code}\n" --max-time 10 "http://<alb-dns-name>/"
```

Expect a timeout (`000` from curl, no HTTP status at all) — a silent connection drop, the signature of a security-group-level block, not a clean rejection. If this instead returns any real HTTP status, the ALB is still directly reachable and the WAF is being bypassed.

## Connect to the RDS database

The RDS instance has `PubliclyAccessible: false` and lives in a private subnet, so it can't be reached directly from your laptop — only from inside the VPC. Its security group only allows MySQL (3306) from `WebServerSecurityGroup`, so one of the WordPress EC2 instances (already in the public subnet) has to act as a jump host.

Get the DB endpoint and an instance's public IP first:

```bash
aws cloudformation describe-stacks \
  --stack-name three-tier-app-network \
  --region us-east-1 \
  --query "Stacks[0].Outputs[?OutputKey=='DBInstanceEndpoint']" \
  --output text
```

(use the "list ASG instances" + "get public IP" commands above to get `<instance-public-ip>`.)

### Option 1: SSH in and use the MySQL client on the instance

A `mysql`-compatible client (`mariadb105`) is already installed there by the WordPress bootstrap script:

```bash
ssh -i <your-key-pair-name>.pem ec2-user@<instance-public-ip>

# once connected:
mysql -h <db-endpoint> -P 3306 -u <username> -p <db-name>
```

It will prompt with `Enter password:` — type your `DBPassword` value there.

### Option 2: SSH tunnel (use a local GUI client or local `mysql` CLI)

```bash
ssh -i <your-key-pair-name>.pem -N -L 3306:<db-endpoint>:3306 ec2-user@<instance-public-ip>
```

Leave that running in its own terminal, then in another terminal or a GUI client (MySQL Workbench, TablePlus, DBeaver, etc.) connect to `127.0.0.1:3306` with `<username>` / `<password>` — traffic is tunneled through the instance to RDS.

### Option 3: DBeaver with its built-in SSH tunnel

DBeaver can tunnel through the jump host itself, without a separate manual `ssh -L` command.

1. **Database → New Database Connection** → choose **MySQL**.
2. **Main** tab:
   - **Server Host**: `<db-endpoint>`
   - **Port**: `3306`
   - **Database**: `<db-name>`
   - **Username**: `<username>`
   - **Password**: `<password>`
3. **SSH** tab → check the **"Use SSH Tunnel"** box at the top (easy to miss — filling in the fields below without checking this does nothing):
   - **Host/IP**: `<instance-public-ip>` (this is the *single* jump host — if your DBeaver version shows a "Jump Servers" list instead of one Host/IP field, add one entry here with these same values; we only need one hop, laptop → this instance → RDS)
   - **Port**: `22`
   - **User Name**: `ec2-user`
   - **Authentication Method**: **Public Key** — DBeaver often defaults this dropdown to **Password**; you must change it explicitly, or the connection fails (see Troubleshooting below)
   - **Private Key**: browse to `<your-key-pair-name>.pem`
   - Leave **Passphrase** blank (unless you set one when creating the key)
4. Click **Test Tunnel Configuration** first (tests just the SSH hop in isolation), then **Test Connection**, then **Finish**.

**Gotcha**: the instance's public IP isn't stable — if the Auto Scaling Group ever replaces that instance (scaling event, health check failure, instance refresh), the SSH tunnel host saved in this connection goes stale. Re-check with the "list ASG instances" + "get public IP" commands above and update the SSH tab's Host/IP.

### Find the actual master username

`DBUsername` is `NoEcho`, so CloudFormation masks it as `****` everywhere, including in `describe-stacks`. The username itself isn't secret to RDS (only the password is), so fetch it directly from the RDS API instead:

```bash
aws rds describe-db-instances \
  --region us-east-1 \
  --query "DBInstances[].[DBInstanceIdentifier,MasterUsername,DBInstanceStatus]" \
  --output table
```

### Reset the master password

If you've lost or forgotten `DBPassword`, reset it without recreating the database:

```bash
aws rds modify-db-instance \
  --db-instance-identifier <db-instance-identifier-from-above> \
  --master-user-password '<new-password>' \
  --apply-immediately \
  --region us-east-1
```

`--apply-immediately` applies the change right away instead of waiting for the next maintenance window. Wait 1-2 minutes for it to take effect before reconnecting with `<new-password>`.

**Note**: this only updates the password on the running RDS instance — it does not update the `DBPassword` value CloudFormation has on record for the stack. On the next `aws cloudformation deploy` (or the change-set workflow above), pass `--parameter-overrides DBPassword=<new-password> ...` explicitly, otherwise CloudFormation will reuse the old (now stale) password value and could try to reset it back.

## Connect to WordPress users

Once you're connected with the `mysql` client (either option above), query the `wp_users` table for the site's registered/admin accounts:

```sql
SELECT ID, user_login, user_email, user_registered FROM wp_users;
```

This table only exists after the WordPress setup wizard (at the `WordPressURL` output) has been completed at least once — a `Table '<db-name>.wp_users' doesn't exist` error means that hasn't happened yet.

To see which role each user has:

```sql
SELECT u.ID, u.user_login, u.user_email, um.meta_value AS capabilities
FROM wp_users u
JOIN wp_usermeta um ON u.ID = um.user_id
WHERE um.meta_key = 'wp_capabilities';
```

## RDS read replica and WordPress read/write splitting

`DBReadReplica` is a MySQL read replica of `DBInstance`, placed explicitly in `SecondAvailabilityZone` (a different AZ than the primary) via `AvailabilityZone: !Ref SecondAvailabilityZone`. WordPress core has no native concept of a read replica — all queries go to whatever's in `DB_HOST` in `wp-config.php`. To actually split reads/writes, `UserData` installs [HyperDB](https://wordpress.org/plugins/hyperdb/) (Automattic's drop-in for this) after WordPress core is in place:

1. Downloads and extracts the HyperDB plugin, copies `db.php` into `wp-content/db.php` — WordPress auto-loads this file if present, and it takes over all database access from the built-in `wpdb` class.
2. Generates `db-config.php` in the webroot (`/var/www/html`, alongside `wp-config.php`, not inside `wp-content`) with two server entries: the primary (`'write' => 1, 'read' => 0`) and the replica (`'write' => 0, 'read' => 1`), both in HyperDB's default `'global'` dataset.

Since `wp-content` is EFS-mounted, `db.php` ends up on the **shared** filesystem (same file visible from every instance); `db-config.php` is written locally by each instance's own `UserData` run (deterministic content from the same CloudFormation parameters every time, so no need to share it via EFS).

### Verify it's actually working

```bash
# on any instance:
cat /var/www/html/wp-content/db.php | head -5          # confirms the HyperDB drop-in is in place
cat /var/www/html/db-config.php                          # confirms both hosts are configured correctly
```

If `db.php` is missing, WordPress silently falls back to its built-in single-connection `wpdb` (talking only to whatever `DB_HOST` is in `wp-config.php`, i.e. the primary) — the site still works, it just isn't actually using the replica for anything. There's no error in this failure mode, so checking the file is the only way to confirm HyperDB is actually active, not just configured in principle.

**That still only proves the config is correct, not that routing actually happens.** For real proof, compare `Com_select` on both hosts before/after generating read traffic — no special privilege needed, just `SHOW GLOBAL STATUS` (not plain `SHOW STATUS`, which is session-scoped and useless here since every new `mysql` connection starts a fresh, zeroed counter):

```bash
# on any instance, with $PRIMARY_HOST/$REPLICA_HOST/$DBUSER/$DBPASS resolved from db-config.php:
mysql -h "$PRIMARY_HOST" -u "$DBUSER" -p"$DBPASS" -e "SHOW GLOBAL STATUS LIKE 'Com_select';"
mysql -h "$REPLICA_HOST" -u "$DBUSER" -p"$DBPASS" -e "SHOW GLOBAL STATUS LIKE 'Com_select';"

for i in $(seq 1 15); do curl -s -o /dev/null http://localhost/; done

# re-run both SHOW GLOBAL STATUS commands - the replica's counter should jump by roughly
# (requests × queries-per-page), the primary's should barely move (background noise only)
```

Live result from this exact test: replica `Com_select` +399 across 15 requests (~27 SELECT queries per WordPress page load), primary +1. Confirms reads are genuinely landing on the replica, not just configured to.

To prove writes land on the primary specifically (not just "the site works"), the decisive test isn't watching counters move together — replication makes the replica's write-related counters move too, just from applying the primary's binlog, which looks identical to a real routing bug at a glance. The actual proof is trying to write to the replica directly and confirming it's rejected:

```bash
mysql -h "$REPLICA_HOST" -u "$DBUSER" -p"$DBPASS" "$DBNAME" -e "INSERT INTO wp_options (option_name, option_value, autoload) VALUES ('should_fail_test', 'x', 'no');"
# expected: ERROR 1290 (HY000): The MySQL server is running with the --read-only option ...
```

If a real `$wpdb` write through WordPress succeeds without error (it does), and a direct write against the replica fails with that exact error, the successful write couldn't have gone anywhere but the primary. This also confirms a fail-safe independent of HyperDB's own config: even a HyperDB misconfiguration couldn't cause a silent write to the replica — it would error loudly instead.

### Known security gaps (not yet remediated — flagged for a decision, not overlooked)

Found during security architect reviews (the first for this feature; a second, stack-wide pass added the items after the first two), deliberately left as-is pending a decision or a planned fix rather than fixed silently:

- **Neither RDS instance is encrypted at rest** (`StorageEncrypted: false` on both). Check with `aws rds describe-db-instances --query "DBInstances[].[DBInstanceIdentifier,StorageEncrypted]"`. This predates the replica, but a read replica must match its source's encryption status — so adding the replica locked this gap into two instances instead of one. Remediation requires snapshot → restore-as-encrypted for the primary (a genuinely disruptive operation — new endpoint, same complexity class as the earlier snapshot-restore work in this file), then recreating the replica from the now-encrypted primary.
- **No TLS enforcement in transit** between the web tier and either RDS instance (`require_secure_transport` unset, using the MySQL engine default). Check with `aws rds describe-db-parameters --db-parameter-group-name <group> --query "Parameters[?ParameterName=='require_secure_transport']"`. Partially mitigated by VPC-level network isolation (unreachable from outside the VPC regardless), but doesn't meet defense-in-depth for data-in-transit on its own. Lower-risk to remediate than the encryption gap — a parameter group change plus adding SSL context to the MySQL/HyperDB connections, no instance replacement needed.
- **The DB master password hasn't been rotated yet.** It's now held in Secrets Manager and no longer in `UserData`, but it's still the value that leaked to CloudWatch Logs and that older launch template versions contain. **Planned:** generate a new random password in the secret and RDS; instances pick it up within a minute (see "DB password in Secrets Manager").
- **Redis has no encryption in transit, at rest, or AUTH token** (`describe-cache-clusters`: `TransitEncryptionEnabled`/`AtRestEncryptionEnabled`/`AuthTokenEnabled` all `false`). Only `RedisSecurityGroup` protects it. **Planned:** an encrypted `ReplicationGroup` with TLS and an AUTH token. At-rest encryption can't be enabled on a `CacheCluster`.
- **The ALB accepts any CloudFront distribution, not just this one.** The origin-facing prefix list covers all of CloudFront, so someone else's distribution pointed at the ALB could bypass this stack's WAF. **In progress:** CloudFront now sends a secret `X-Origin-Verify` header, stored in Secrets Manager as `three-tier-app-origin-verify`. The next step makes the ALB listener reject requests without it (fixed 403). That has to be a separate deploy, after CloudFront is already sending the header, or the site would go down.
- **No Multi-AZ** on the RDS primary (roughly doubles RDS cost). Deletion protection is now on for both instances.
- **WordPress connects as the RDS master user**, not a least-privilege application user.
- **Smaller hardening items:** no explicit `MetadataOptions` (IMDSv2 is enforced today only by the AL2023 AMI default), plain HTTP on the in-VPC ALB→instance hop, unpinned WordPress/plugin downloads with no checksum, `chmod -R 755` leaving config files world-readable, no CloudFront security-headers policy, no `aws:SecureTransport` deny on the ALB logs bucket, GitHub Actions pinned by tag rather than SHA, and `DB_PASSWORD` interpolated straight into a `run:` shell line.
- **Accepted, not planned:** web servers in public subnets. Moving them to private subnets needs a NAT Gateway (~$33/month + $0.045/GB), which would roughly double the running cost; the security groups already limit HTTP to the ALB and SSH to one IP.

### Known limitation: replication lag

Read replicas are asynchronous — there's a small delay between a write landing on the primary and it becoming visible on the replica. HyperDB's simple two-server config here doesn't implement "read-your-own-writes" handling (e.g. temporarily routing reads to the primary for the rest of a request right after that same request performed a write). In practice this means: publishing a post and immediately being redirected to view it could, in rare cases under load, briefly show stale data if that view's read lands on the replica before replication catches up. For a portfolio-scale demo this is a non-issue (lag is typically sub-second, single low-traffic site), but it's a real production consideration HyperDB supports handling more robustly (via its `dataset`/callback mechanism) that this simple config doesn't use.

### After adding/changing anything replica-related

Same rule as any other `UserData` change: a stack update alone doesn't touch already-running instances. Run an instance refresh (see "Update running instances after a launch template change" above) to actually roll out `db.php`/`db-config.php` to instances that existed before this feature was added.

## Redis object cache (ElastiCache)

`RedisCluster` is a single-node ElastiCache Redis cluster (`RedisNodeType`, default `cache.t3.micro` — eligible for the ElastiCache free tier) in the private subnets, reachable only from `WebServerSecurityGroup` on port 6379 (`RedisSecurityGroup`). No Multi-AZ, no encryption, no snapshot policy — the same single-node simplicity tradeoff as the RDS primary, and unlike RDS, cache data is inherently disposable (rebuilt from the database on the next read), so there's nothing worth preserving through a node failure or stack teardown.

**Cost added**: `cache.t3.micro` is $0.014/hour on-demand in `us-east-1` (verified via `aws pricing get-products`), roughly ~$10/month — free for the first 12 months on an eligible new AWS account under ElastiCache's free tier (750 node-hours/month), which covers this single node's usage entirely as long as nothing else in the account is also consuming that same free tier allowance. Brings the running total from the earlier ~$57-61/month estimate to roughly **$67-71/month** (or ~$57-61/month if still within the ElastiCache free tier).

WordPress has no built-in object cache backend beyond a per-request in-memory array. `UserData` installs the [Redis Object Cache](https://wordpress.org/plugins/redis-cache/) plugin's `object-cache.php` **drop-in** directly into `wp-content` — the same mechanism as HyperDB's `db.php` above, and exactly what clicking "Enable Object Cache" in the plugin's admin UI does, just automated:

1. `php8.3-pecl-redis6` (the native PhpRedis extension, confirmed available for Amazon Linux 2023's php8.3 package) is installed alongside the other PHP packages, so the plugin doesn't fall back to its slower pure-PHP Predis client.
2. Downloads the plugin, copies `redis-cache/includes/object-cache.php` to `wp-content/object-cache.php`.
3. Appends `WP_REDIS_HOST`/`WP_REDIS_PORT` (pointing at `RedisCluster`'s endpoint) to `wp-config.php`, the same insert-after-marker approach already used for the CloudFront-Forwarded-Proto fix.

This caches expensive, repeated database reads — `WP_Query` results, post meta, comment queries, transients, options — across requests and across instances (every instance in the Auto Scaling Group shares the same Redis cluster), which is what actually reduces load on `DBInstance` under real traffic; HyperDB's read replica helps with read *scaling*, this helps with read *avoidance* entirely for cacheable data.

### Verify it's actually caching, not just installed

Same principle as everywhere else in this file. Confirm the extension loaded, the drop-in is in place, and — the only proof that matters — that Redis actually contains real WordPress cache entries after normal site traffic:

```bash
# on any instance:
php -m | grep -i redis                                    # confirms the PhpRedis extension loaded
grep WP_REDIS_HOST /var/www/html/wp-config.php             # confirms the connection config is present
```

```bash
# a quick direct connectivity + content check (uses the extension directly, no wp-cli needed):
php -r "
\$r = new Redis();
\$r->connect('<redis-endpoint>', 6379, 2);
echo 'DBSIZE: ' . \$r->dbSize() . PHP_EOL;
foreach (array_slice(\$r->keys('*'), 0, 10) as \$k) { echo \$k . PHP_EOL; }
"
```

Live result from this exact test after a normal instance refresh (no synthetic traffic): `DBSIZE: 126`, with keys like `wp:post-queries:wp_query-<hash>`, `wp:post_meta:<id>`, `wp:comment-queries:get_comments-<hash>`, and `wp:site-transient:update_themes` — real WordPress cache groups, not test data, confirming the object cache is actively populated from real page loads rather than merely configured.

### Fallback behavior if Redis is unreachable

The Redis Object Cache plugin is documented to catch connection failures and fall back to WordPress's default non-persistent (per-request, in-memory) object cache automatically, rather than a fatal error — so a Redis outage means degraded performance (every request re-queries the database, same as before this feature existed), not site downtime. This wasn't verified against this specific deployment with a live failure test (that would mean temporarily revoking `RedisSecurityGroup`'s ingress rule in production, a real if brief security-relevant change not taken without asking first) — treat it as the plugin's documented behavior rather than something proven here. To verify it yourself: temporarily remove the ingress rule, confirm the site still loads (slower, and `WP_REDIS_DISABLED`/connection-error notices may appear depending on `WP_DEBUG`), then restore it.

### After adding/changing anything Redis-related

Same rule as the read replica above: a stack update alone doesn't touch already-running instances. Run an instance refresh to roll out the extension, plugin drop-in, and `wp-config.php` changes to instances that existed before this feature was added.

### Direct SQL writes to `wp_options` no longer take effect on their own

Discovered when renaming the custom domain: `siteurl`/`home` were updated correctly in the database, but `/wp-admin` kept redirecting to the *old* domain's `wp-login.php` anyway. The database was right; a direct `UPDATE wp_options` bypasses WordPress's own caching layer entirely, so the Redis-cached copy of the bulk-loaded autoloaded options (cache key `wp:options:alloptions`) kept serving the old value indefinitely — nothing about a raw SQL write tells Redis to invalidate it. This wasn't a problem before Redis existed (no cross-request cache to go stale), so every prior `wp_options` fix in this file predates the issue.

**Fix**: flush the object cache immediately after any direct SQL write to `wp_options` (or any other table WordPress caches):

```bash
php -r "\$r = new Redis(); \$r->connect('<redis-endpoint>', 6379); \$r->flushDb();"
```

Safe to run any time — the object cache is entirely disposable and gets rebuilt from the database on the next read. Verified: after flushing, `/wp-admin` redirected to the correct, newly-updated domain immediately, with no other change needed.

## AWS Backup

`BackupVault` is a dedicated vault; `BackupPlan` runs one rule (`Daily`) on a cron schedule (`BackupScheduleExpression`, default `cron(0 5 * * ? *)` — 05:00 UTC daily) with a 30-day retention (`BackupRetentionDays`) before AWS Backup deletes each recovery point. `BackupServiceRole` is the service role AWS Backup assumes to actually create backups, using the AWS-managed `AWSBackupServiceRolePolicyForBackup` policy.

`BackupSelection` decides what gets backed up, and uses two different mechanisms deliberately:
- **RDS (`DBInstance`) and EFS (`EFSFileSystem`) by explicit ARN** (`!GetAtt ...Arn`) — each is a single, known resource, so there's nothing to gain from tag-based matching.
- **EC2 by tag** (`Name` = `${EnvironmentName}-wordpress`, the tag the Auto Scaling Group already propagates to every instance at launch) — instances get replaced by the ASG over time, so a static instance ID/ARN would silently stop covering new instances. Tag-based selection keeps working automatically as instances come and go.

`DBReadReplica` is deliberately **not** included. It's derived entirely from the primary via replication — restoring it independently doesn't make sense; recovering the primary and re-creating a replica from it does.

**Relationship to RDS's own automated backups** (`DBBackupRetentionPeriod`): these are complementary, not redundant. RDS's built-in backups exist for short-window point-in-time recovery (its own storage, its own lifecycle, capped at `DBBackupRetentionPeriod` days). This AWS Backup plan is a separate, centralized, longer-retention (30 days) mechanism spanning RDS *and* EFS *and* EC2 in one named vault — useful for a broader disaster-recovery/compliance story, not a replacement for RDS's short-term PITR window.

**Cost added**: billed per-resource, verified via `aws pricing get-products` rather than guessed — RDS backup storage is $0.095/GB-month (but RDS grants a free backup storage allowance equal to total provisioned RDS storage across the account, so this may cost nothing until snapshots collectively exceed that), EFS backup storage is $0.05/GB-month, EC2 (AMI/EBS snapshot) backup storage is $0.05/GB-month. RDS snapshots are incremental after the first, so actual monthly cost depends on how much data actually changes day to day — not something to estimate confidently in advance; check Cost Explorer under "AWS Backup" after the 30-day retention window has fully filled once.

### Verify it's actually working, not just scheduled

Same principle as everywhere else in this file — a `BackupPlan` resource existing doesn't prove a backup can actually complete (wrong IAM permissions, an unreachable resource, or a bad ARN in the selection would all deploy cleanly and then silently fail on the first scheduled run, hours or days later). Trigger an on-demand job instead of waiting for the schedule:

```bash
aws backup start-backup-job \
  --backup-vault-name <vault-name> \
  --resource-arn <resource-arn> \
  --iam-role-arn <backup-role-arn> \
  --region us-east-1

# poll:
aws backup describe-backup-job --backup-job-id <job-id> --region us-east-1 --query "[State,StatusMessage,BackupSizeInBytes]"
```

Live result from this exact test: an on-demand EFS backup completed in well under a minute (`BackupSizeInBytes: 16353060`, ~15.6 MB), and an on-demand RDS backup also completed (`COMPLETED`) — both landing as recovery points in the vault (`aws backup list-recovery-points-by-backup-vault --backup-vault-name <vault-name>`), not just accepted-and-forgotten jobs.

**RDS-specific gotcha**: the RDS recovery point reported `BackupSizeInBytes: 0` even though its status was `COMPLETED` — this looked like a false success at first. Checked the actual underlying snapshot AWS Backup created (`aws rds describe-db-snapshots --snapshot-type awsbackup`) and found it genuinely `available` at 100% progress with the DB's full 20 GiB allocated storage — a real, complete snapshot. AWS Backup's own size reporting for RDS-type recovery points is known to lag or not populate; `COMPLETED` status plus a direct check against the underlying RDS snapshot is the reliable way to confirm an RDS backup actually worked, not the `BackupSizeInBytes` field.

### Restoring from a recovery point

Not exercised end-to-end here (would mean actually restoring over live infrastructure), but the mechanism: `aws backup start-restore-job --recovery-point-arn <arn> --iam-role-arn <backup-role-arn> --metadata <resource-specific-metadata> --region us-east-1`. RDS and EFS restores create a **new** resource (a new DB instance, a new file system) rather than overwriting the original in place — the same principle as the RDS snapshot-restore path already documented above, and worth remembering before assuming "restore" means "revert this exact resource."

## DB password in Secrets Manager

The RDS master password lives in the Secrets Manager secret **`three-tier-app-db-master`** (`{"username": ..., "password": ...}`). It's no longer in `UserData`, the launch template, `wp-config.php` or `db-config.php`:

- **RDS** reads it with a dynamic reference: `MasterUserPassword: '{{resolve:secretsmanager:<secret>:SecretString:password}}'`.
- **Instances** fetch it at boot. `/usr/local/bin/refresh-db-secret` writes `/etc/wordpress/db-secret.php` (`define('DB_PASSWORD', ...)`) outside the web root, owned `root:apache`, mode `640`, via an atomic temp-file-and-rename. `wp-config.php` `require`s that file, and HyperDB's `db-config.php` uses the `DB_PASSWORD` constant for both the primary and the replica.
- **A systemd timer (`refresh-db-secret.timer`) re-runs it every minute.** A rotated password is picked up within about a minute, with no instance replacement. PHP's opcache re-checks included files' timestamps by default, so no restart is needed either.
- The instance role (`three-tier-app-cw-agent-role`) gets `secretsmanager:GetSecretValue` on this one secret. That's within `AppRoleBoundary`, which already allowed `three-tier-app-*` secrets.
- The script never echoes the value, so `bash -x` tracing in `UserData` only shows the command name.

**Migration without downtime:** the secret was first **seeded with the existing `DBPassword` value**, so switching RDS and the instances to it changed nothing. Rotating to a new random value is a separate step. Doing both at once would have changed the RDS password while the old instances (being replaced one at a time over about 20 minutes) still had the old one baked in.

**Deploy order for this change:** the deploy role needed new `secretsmanager` permissions in `pipeline.yaml`. That stack is admin-deployed, so redeploy it **before** merging an app-stack change that adds secrets:

```bash
aws cloudformation deploy --template-file cloudformation/pipeline.yaml --stack-name three-tier-app-pipeline \
  --region us-east-1 --capabilities CAPABILITY_NAMED_IAM
```

**Verify on an instance:**

```bash
systemctl list-timers refresh-db-secret.timer        # next/last run
sudo ls -l /etc/wordpress/db-secret.php               # -rw-r----- root apache
sudo journalctl -u refresh-db-secret --since -10min   # should show successful runs, never the value
grep -n "DB_PASSWORD\|db-secret" /var/www/html/wp-config.php   # only the require line
```

**Cost:** $0.40/month per secret (two: this one and `three-tier-app-origin-verify`), plus $0.05 per 10,000 API calls. The 1-minute timer on 2–3 instances makes about 130k calls a month, roughly $0.65/month.

## Troubleshooting

Every issue actually hit while building and operating this stack, with symptom → cause → fix. Check here first before re-diagnosing from scratch.

### CloudFormation fails: "Invalid rule description. Valid descriptions are strings less than 256 characters from the following set: ..."

- **Symptom**: `AWS::EC2::SecurityGroupIngress` (or an inline `SecurityGroupIngress` entry) fails to create with this exact message, listing an allowed character set.
- **Cause**: EC2 security group rule `Description` fields only accept a specific character set — notably **no apostrophe**. `HTTP access from CloudFront's origin-facing IP ranges only` failed for exactly this reason (the `'` in "CloudFront's"). Easy to miss since apostrophes look completely ordinary in prose, and most other AWS string fields (tags, resource descriptions elsewhere in this same template) don't have this restriction.
- **Fix**: Reword to avoid the character entirely (`CloudFront origin-facing IP ranges` instead of `CloudFront's origin-facing IP ranges`) rather than trying to escape it — the allowed set has no escape mechanism, the character simply isn't permitted.
- **General lesson**: this specific field has a narrower allowed character set than most other AWS string properties. Worth a second look at rule/security-group `Description` text specifically (not just parameter values, which is where the previous "excludes `'`" lesson from `DBPassword` came from) before assuming any plain English sentence is safe to use verbatim.

### `/wp-admin` redirects to itself forever

- **Symptom**: `curl -v https://<cloudfront-domain>/wp-admin/` returns `302` with `location:` pointing at the *exact same URL* (`/wp-admin/` → `/wp-admin/`), not `wp-login.php`. Every retry produces the identical response — a genuine infinite loop, not a normal not-logged-in redirect. The rest of the site (homepage, etc.) loads fine.
- **Cause**: The ALB origin is HTTP-only, so the `X-Forwarded-Proto` header WordPress sees always reads `http` (it reflects the CloudFront-to-ALB hop, added by the ALB itself, not the viewer-to-CloudFront hop). With `siteurl`/`home` set to the `https://` CloudFront domain, WordPress thinks every request arrived over the wrong scheme and keeps "correcting" it — into the same wrong state, forever.
- **How this was actually diagnosed**: A quick PHP script dumping every `HTTP_*` / `HTTPS` entry in `$_SERVER`, hit through CloudFront, confirmed `HTTP_X_FORWARDED_PROTO=http` even though the original request was HTTPS — ruling out a guess-and-check fix. The same dump showed `HTTP_CLOUDFRONT_FORWARDED_PROTO` was simply absent, because the origin request policy in use at the time (`AllViewer`) doesn't forward CloudFront's own `CloudFront-*` headers — only real viewer-sent headers.
- **Fix**: Two parts, both needed together:
  1. Switch the distribution's `OriginRequestPolicyId` to the managed `AllViewerAndCloudFrontHeaders-2022-06` policy (`33f36d7e-f396-46d9-90e0-52428a34d9dc`), so `CloudFront-Forwarded-Proto` (the viewer's *real* protocol) actually reaches the origin.
  2. In `wp-config.php`, treat that header — not `X-Forwarded-Proto` — as the signal:
     ```php
     if ( isset( $_SERVER['HTTP_CLOUDFRONT_FORWARDED_PROTO'] ) && $_SERVER['HTTP_CLOUDFRONT_FORWARDED_PROTO'] === 'https' ) {
     	$_SERVER['HTTPS'] = 'on';
     }
     ```
  Both are baked into the template now (`CloudFrontDistribution`'s origin request policy and the web server `UserData`, respectively), so new instances get this automatically — no manual step needed for future deploys.
- **General lesson**: on a distribution whose origin is HTTP-only, `X-Forwarded-Proto` is not a reliable signal for "what protocol did the viewer actually use" — it's set by whatever's immediately upstream of the origin (here, the ALB's own listener), not the original viewer. `CloudFront-Forwarded-Proto` is the header that actually carries that information, and it has to be explicitly opted into via the origin request policy.

### GitHub Actions OIDC: "Could not assume role with OIDC: Not authorized to perform sts:AssumeRoleWithWebIdentity"

- **Symptom**: The workflow's "Configure AWS credentials via OIDC" step retries `Assuming role with OIDC` for a couple of minutes, then fails with this exact message. The role, the OIDC provider, and the GitHub secret all "look" correctly configured.
- **Cause**: GitHub's OIDC token `sub` claim format is `repo:<org>@<org-numeric-id>/<repo>@<repo-numeric-id>:ref:refs/heads/<branch>` — it embeds **immutable numeric IDs** alongside the org/repo names, not just `repo:<org>/<repo>:ref:refs/heads/<branch>`. A trust policy condition written with the simpler (older-looking, but actually just wrong) format silently never matches, and STS returns a generic "not authorized" with no hint about *why* — it doesn't tell you the actual `sub` value it received.
- **How this was actually diagnosed**: The workflow logs don't show token contents (by design). CloudTrail does — it logs the denied `AssumeRoleWithWebIdentity` call, and the real presented `sub` claim shows up in `userIdentity.principalId`:
  ```bash
  aws cloudtrail lookup-events \
    --lookup-attributes AttributeKey=EventName,AttributeValue=AssumeRoleWithWebIdentity \
    --region us-east-1 --max-results 1 \
    --query "Events[0].CloudTrailEvent" --output text | python3 -m json.tool
  ```
  Look at `userIdentity.principalId` in the result — that's the exact `sub` string GitHub sent, ground truth instead of guessing.
- **Fix**: Get the real numeric IDs and put them in the trust policy (this template's `GitHubOrgId`/`GitHubRepoId` parameters):
  ```bash
  gh api users/<org> --jq '.id'
  gh api repos/<org>/<repo> --jq '.id'
  ```
  Then redeploy with `GitHubOrgId`/`GitHubRepoId` set, so the condition becomes `repo:${GitHubOrg}@${GitHubOrgId}/${GitHubRepo}@${GitHubRepoId}:ref:refs/heads/${GitHubBranch}`.

### GitHub Actions OIDC breaks again after adding an `environment:` to a job

- **Symptom**: The exact same `AssumeRoleWithWebIdentity`/`AccessDenied` failure as above, but on a workflow that was working fine — the only recent change was adding a manual approval gate (`environment: production` on the `deploy` job).
- **Cause**: GitHub's OIDC token `sub` claim format is different for a job that targets an Environment: `repo:<org>@<id>/<repo>@<id>:environment:<name>`, not the `:ref:refs/heads/<branch>` format used otherwise. Adding `environment:` to a job **changes what `sub` value it presents** — the trust policy condition that matched before stops matching, silently, with the same generic "not authorized" error as the numeric-ID issue above.
- **How this was actually diagnosed**: same CloudTrail lookup as the entry above — `userIdentity.principalId` on the denied call showed `...:environment:production` where the trust policy still expected `...:ref:refs/heads/main`.
- **Fix**: list both `sub` formats in the trust policy's `StringEquals` condition (IAM matches a `StringEquals` condition against *any* value in a list, not just the first):
  ```yaml
  token.actions.githubusercontent.com:sub:
    - !Sub repo:${GitHubOrg}@${GitHubOrgId}/${GitHubRepo}@${GitHubRepoId}:ref:refs/heads/${GitHubBranch}
    - !Sub repo:${GitHubOrg}@${GitHubOrgId}/${GitHubRepo}@${GitHubRepoId}:environment:production
  ```
- **General lesson**: any change to *how* a job runs (adding an environment, a matrix, a reusable-workflow call, etc.) can silently change the OIDC `sub` claim GitHub presents. Treat a trust policy condition as tied to the exact job configuration it was written against, and re-verify it (via CloudTrail, not assumption) after changing that configuration — not just after changing the org/repo/branch values it references.

### Deploy fails trying to re-create a resource you already removed live

- **Symptom**: An unrelated PR (one that doesn't touch `cloudformation/vpc.yaml` at all, e.g. a docs-only or `.gitignore`-only change) merges to `main`, triggers a deploy, and the deploy fails — `describe-stack-events` shows CloudFormation trying to *create* a resource that doesn't exist and doesn't seem related to the merged PR.
- **Cause**: a previous fix was applied to the *live stack* directly via `aws cloudformation execute-change-set` (using a local branch's template file) but its branch was never actually merged to `main`. `main`'s committed template still declares the old resource. The next deploy — triggered by *any* change to `main`, even a completely unrelated one — uses `main`'s stale template, sees the old resource is "missing" from CloudFormation's tracked state, and tries to recreate it to match what the template says should exist. If that resource happened to be removed for a real reason (e.g. a security-group rule quota conflict — see "CloudFront-to-ALB traffic is now HTTPS" above), recreating it fails the exact same way it did the first time.
- **How this was actually diagnosed**: `describe-stack-events` on the failed update showed the *old*, already-removed `ALBListener`/`ALBSecurityGroupIngressFromCloudFront` resources being created, not modified — a clear sign the template CloudFormation was deploying didn't match what was actually live, confirmed by checking that the live ALB only had the new HTTPS listener while `main`'s template still declared the old HTTP one.
- **Fix**: finish and merge the branch containing the live fix, so `main`'s template matches reality. Verified the fix was complete by running a change-set against the live stack with no parameter changes and confirming CloudFormation reports "The submitted information didn't contain changes" — proof the template and the live stack are now identical, not just that it deployed without erroring.
- **General lesson**: applying a fix directly to a live stack (via a manual change-set, for speed or because CloudFormation's own resource-swap ordering can't express the needed sequence) is sometimes the right call, but it creates a *live/repo drift* that persists — and actively causes failures — until the corresponding branch is actually merged. An unmerged "already deployed" branch isn't done; it's a ticking time bomb for the next unrelated deploy. Treat "verified live" and "merged" as two separate completion criteria, not one.

### GitHub Actions deploy fails: "AccessDenied ... cloudformation:GetTemplateSummary"

- **Symptom**: OIDC assume-role succeeds (progress — see the previous entry), but the very next step, `aws cloudformation deploy`, fails almost immediately with `User: .../GitHubActionsDeployRole/GitHubActions is not authorized to perform: cloudformation:GetTemplateSummary`.
- **Cause**: `aws cloudformation deploy` isn't a single API call — it internally calls `GetTemplateSummary` (to inspect the template's parameters before building the change set) in addition to the change-set actions. It's easy to enumerate the "obvious" CloudFormation actions (`CreateChangeSet`, `ExecuteChangeSet`, `DescribeStacks`, etc.) when writing an IAM policy and miss this one, since it's not part of the change-set lifecycle itself.
- **Fix**: Add `cloudformation:GetTemplateSummary` to the role's CloudFormation action list, scoped to the same stack ARN as the other CloudFormation actions.
- **General lesson for this role's policy**: since AWS CLI's higher-level commands (`deploy`, and others) can call additional APIs beyond what their name suggests, expect to discover a missing permission or two the first time a new IAM policy is exercised for real, even after careful review. This is exactly what a working end-to-end test (an actual push through the actual workflow, not just re-reading the policy) is for.

### ALB update fails: "Access Denied for bucket ... Please check S3 bucket permission"

- **Symptom**: `ApplicationLoadBalancer UPDATE_FAILED` (or `CREATE_FAILED`) with this message when enabling `access_logs.s3.enabled`.
- **Cause**: The bucket policy's `Resource` ARN didn't match the actual object path the ALB writes to. `access_logs.s3.prefix` (set to `alb-logs`) means objects land at `<bucket>/alb-logs/AWSLogs/<account-id>/...`, but the bucket policy only granted access to `<bucket>/AWSLogs/<account-id>/*` — missing the `alb-logs/` prefix segment. The path in the bucket policy must match the prefix configured on the load balancer exactly.
- **Fix**: Make sure `ALBLogsBucketPolicy`'s `Resource` ARNs include the same prefix set in the ALB's `access_logs.s3.prefix` attribute: `arn:aws:s3:::<bucket>/<prefix>/AWSLogs/${AWS::AccountId}/*`. If you change the prefix, update the bucket policy to match, or logging silently fails with this Access Denied error the moment it's enabled.

### Deploy fails: "Requires capabilities : [CAPABILITY_NAMED_IAM]"

- **Symptom**: `aws cloudformation deploy` fails immediately (no change set / stack event even created) with this message.
- **Cause**: The stack includes a named IAM role (`CloudWatchAgentRole`, used by the CloudWatch agent on each instance). CloudFormation refuses to create or update any IAM resource unless you explicitly acknowledge that in the command.
- **Fix**: Add `--capabilities CAPABILITY_NAMED_IAM` to the `deploy` command (every example in this file already includes it).

### `ValidateTemplate`/`deploy` fails: template body exceeds the inline size limit

- **Symptom**: `aws cloudformation validate-template` (or `deploy`, including in CI) fails with a `ValidationError` whose message oddly echoes back the *entire template body* as the "Value" that failed a constraint, rather than describing an actual template problem.
- **Cause**: `TemplateBody` (used when passing a local file directly, as every command in this file and `deploy.yml` does — no S3 upload step) has a hard **51,200-byte** limit. This template sits close to that ceiling because of its (deliberately) thorough inline comments; it's easy to cross it with an otherwise-small, correct change; the error message doesn't mention size at all, so it looks like a validation failure on the content rather than a size limit on the parameter.
- **Fix**: `wc -c cloudformation/vpc.yaml` to confirm; trim comment text (without losing the load-bearing "why," just tightening the wording) until back under the limit, ideally with some margin for the next change. The real fix for a template that's outgrown this permanently would be `--template-url` via an S3-uploaded copy (`aws cloudformation package`) instead of `--template-body`, but that adds a build step to `deploy.yml` that doesn't exist today — not worth it while trimming keeps working.
- **General lesson**: this limit applies identically in CI (`deploy.yml` uses `--template-file`, which the CLI still sends as `TemplateBody` under this same limit) — a PR that passes `cfn-lint` cleanly can still fail at deploy time on `push` to `main` for a reason `cfn-lint` has no way to catch, since it's an API-level constraint, not a template-correctness one.
- **Hit again (PR #21)**: a 3-line `set +x` change took the template from 51,155 to 51,357 bytes. It passed `cfn-lint`, merged, and then failed on deploy. Trimmed the longest parameter/template descriptions (down to ~50,350 bytes). `validate.yml` now has a **"Check template size"** step that fails the PR if the template is over 51,200 bytes, so this is caught before merge instead of after.
- **Permanent fix, step 1 of 2**: the stack now has a `CfnArtifactsBucket` (auto-named `three-tier-app-network-cfnartifactsbucket-*`, so it already falls inside `GitHubActionsDeployRole`'s S3 scope, which gained `s3:PutObject`/`GetObject`/`ListBucket`), with templates expiring after 7 days. This has to deploy through the old inline path first, since the role can't upload to a bucket that doesn't exist yet. Step 2 switches `deploy.yml` to `--s3-bucket` (limit becomes 1 MB).
- **Permanent fix, step 2 of 2**: `deploy.yml` now uploads the template to `CfnArtifactsBucket` and validates/deploys it by URL (`validate-template --template-url`, `deploy --s3-bucket`). The limit is now **1 MB**, and `validate.yml`'s size check was raised to match. **Manual deploys** from your machine hit the same 51,200-byte limit once the template grows past it again. Add `--s3-bucket $(aws cloudformation describe-stacks --stack-name three-tier-app-network --query "Stacks[0].Outputs[?OutputKey=='CfnArtifactsBucketName'].OutputValue" --output text)` to any `aws cloudformation deploy` command in this file.

### PR checks stop running / stuck `pending` forever

- **Symptom**: after pushing a new commit to a PR's branch, the `validate` check never starts (or the previous commit's result just sits there, no new run appears at all — `gh run list` shows nothing for the new commit's SHA).
- **Cause**: the PR is in a `DIRTY`/`CONFLICTING` merge state relative to `main` (check with `gh pr view <number> --json mergeable,mergeStateStatus`). GitHub doesn't reliably fire `pull_request` check runs against a PR that can't currently be merged — this happens most often when two branches were both open at once and one of them merged first, leaving the other's diff colliding with the new `main`. It looks exactly like a CI/workflow bug from the outside (no error, just silence), but it isn't one.
- **Fix**: resolve the conflict — `git fetch origin main && git rebase origin/main`, resolve any conflict markers, `git push --force-with-lease` (safe on your own feature branch, not on `main`). Once `mergeable` flips back to `MERGEABLE`, checks start firing normally again on the very next push, with no other change needed.
- **General lesson**: keep feature branches short-lived and rebase before starting new work if another PR might land first (see "Git workflow" above) — this class of conflict is much rarer the fewer long-lived parallel branches exist touching the same files.

### App stack deploy fails: "No export named three-tier-app-pipeline-... found"

- **Symptom**: the deploy workflow fails right after "Waiting for stack create/update to complete". The stack goes to `UPDATE_ROLLBACK_COMPLETE` with the reason `No export named three-tier-app-pipeline-backup-role-arn found`.
- **Cause**: the app stack's `Fn::ImportValue`s reference the pipeline stack's exports, and the pipeline stack didn't exist yet. This really happened: PR #25 (which introduced `pipeline.yaml`) was merged *before* its "deploy the pipeline stack first" steps were run, so the merge-triggered deploy ran too early.
- **Fix**: deploy `pipeline.yaml` (see "One-time AWS-side setup"), update `AWS_DEPLOY_ROLE_ARN`, then re-run the failed workflow run (`gh run rerun <run-id>`, or "Re-run jobs" in the Actions tab). Nothing needs reverting: the failure happens before any resource changes. A re-run reads the secret when its "Configure AWS credentials" step runs (after approval), not when the run was first created, so it picks up the new role ARN.
- **General lesson**: when a PR needs manual steps before its deploy, merging *is* the trigger. Do the steps first, then merge.

### Retargeting a stacked PR's base branch doesn't run the `validate` check

- **Symptom**: after the PR it was stacked on merges, a PR is retargeted to `main` (`gh api -X PATCH .../pulls/<n> -f base=main`) and marked ready, but no `validate` check appears, so the PR stays `BLOCKED`.
- **Cause**: `validate.yml` triggers on `pull_request` with the default activity types (`opened`, `synchronize`, `reopened`). Changing the base branch fires an `edited` event, which isn't in that list.
- **Fix**: close and reopen the PR (`gh pr close <n> && gh pr reopen <n>`). That fires `reopened` without touching the branch's commits. Pushing a new commit (`synchronize`) also works.
- **Side note**: `gh pr edit` can fail outright on some `gh` versions with a GraphQL "Projects (classic) is being deprecated" error. The REST call above works regardless.

### cfn-lint W3005 / W1011 findings on pull requests

- **W3005** ("`'<X>'` dependency already enforced by a `'Ref'`/`'GetAtt'` at ...") fires whenever a resource has both an explicit `DependsOn` entry *and* a `Ref`/`Fn::GetAtt` reference to that same resource elsewhere in its properties (or, for `WebServerLaunchTemplate`, inside its `UserData` string) — the explicit entry is redundant, since CloudFormation already infers the dependency from the reference. Hit this repeatedly (`DBInstance`, `DBReadReplica`, `HttpdErrorLogGroup`, `CloudInitLogGroup` in various resources' `DependsOn` lists) — the fix each time was simply removing the redundant entry, not adding a suppression. Only keep an explicit `DependsOn` for a resource that's genuinely *not* referenced anywhere in that resource's properties (e.g. `EFSMountTarget1`/`EFSMountTarget2` on `WebServerLaunchTemplate` — nothing in `UserData` references them directly, only `EFSFileSystem`, so their dependency has to stay explicit).
- **W1011** ("Use dynamic references over parameters for secrets") fired on `MasterUserPassword: !Ref DBPassword` in `DBInstance`, suggesting an AWS Secrets Manager dynamic reference instead of a plain `NoEcho` parameter. For a long time it was **deliberately suppressed** (a per-resource `Metadata: cfn-lint: config: ignore_checks: [W1011]` block), since GitHub Secrets seemed enough at this scale. **That decision was reversed** after a security review found the password in CloudWatch Logs and in every launch template version. `MasterUserPassword` now uses `{{resolve:secretsmanager:...}}` and the suppression is gone. See "DB password in Secrets Manager".
- **Exit codes**: `cfn-lint` returns non-zero for warnings, not just errors — a bare `cfn-lint template.yaml` failing doesn't necessarily mean anything is actually broken, just that it found something to flag. Read the actual finding before assuming the template is wrong.

### Why does the RDS error log group need a custom resource for retention?

- **Context**: `DBInstance` has `EnableCloudwatchLogsExports: [error]`, which makes RDS create a CloudWatch Logs group automatically, with default (never expire) retention. A plain `AWS::Logs::LogGroup` resource (like `HttpdErrorLogGroup`/`CloudInitLogGroup`) can't be used to manage it directly.
- **Why not**: The log group's name depends on the DB instance's identifier (`/aws/rds/instance/<identifier>/error`), and `DBInstance` doesn't set an explicit `DBInstanceIdentifier` — AWS auto-generates one. A CloudFormation-managed `AWS::Logs::LogGroup` would have to `DependsOn: DBInstance` to know the name, but by the time `DBInstance` finishes creating, RDS has typically already auto-created that same log group as a side effect of enabling the export — so the CloudFormation resource creation fails with "already exists." Giving `DBInstance` an explicit `DBInstanceIdentifier` to work around the naming problem isn't an option either: that property is immutable and triggers replacement, so adding it to an already-running stack would **replace the live database**.
- **Fix**: `DBErrorLogRetention` (`Custom::SetRdsLogRetention`), backed by the `RdsLogRetentionFunction` Lambda, calls `logs:PutRetentionPolicy` directly via the API instead of declaring the log group as a CloudFormation-managed resource. This works whether the log group already exists or not — the call is idempotent, and the Lambda retries (up to 10 times, 6s apart) if the log group doesn't exist yet when it first runs. No naming conflict, no `DBInstanceIdentifier` change, no replacement risk.
- If you ever need to set it manually (e.g. testing before this Lambda existed): `aws logs put-retention-policy --log-group-name /aws/rds/instance/<db-instance-identifier>/error --retention-in-days 7 --region us-east-1`

### RDS create fails: "backup retention period exceeds the maximum available to free tier customers"

- **Symptom**: `DBInstance CREATE_FAILED` with that exact message in `describe-stack-events`.
- **Cause**: `BackupRetentionPeriod` was set above what a free-tier account allows.
- **Fix**: Keep `DBBackupRetentionPeriod` at its default (`1`). Only raise it once the account is off the RDS free tier.

### WordPress shows "Error establishing a database connection" (500 from the ALB)

- **Symptom**: ALB target group reports `Target.ResponseCodeMismatch` / `500`; visiting the site (or `wp-admin`) shows WordPress's "Error establishing a database connection" page.
- **Cause**: The password baked into `wp-config.php` (from the `DBPassword` parameter at the time the instance booted) doesn't match RDS's actual current master password. Usually happens after someone runs `aws rds modify-db-instance --master-user-password ...` directly, bypassing CloudFormation.
- **Fix**:
  1. Update the CloudFormation stack's `DBPassword` parameter to the same value the RDS password was reset to (see "Reset the master password" below) — this creates a new launch template version with the correct password.
  2. Run an instance refresh (see "Update running instances after a launch template change") so running instances actually pick up the new launch template — a stack update alone does not touch instances already running.

### WordPress shows a "Database Error" page (not "Error establishing a database connection")

- **Symptom**: Different WordPress error screen — this one means the DB *connection and authentication succeeded*, but selecting the configured database failed.
- **Cause**: `DB_NAME` in `wp-config.php` (from the `DBName` parameter) doesn't match the actual schema name in RDS. This happens easily after restoring from a snapshot taken under a different `DBName` value than what's passed on the restoring deploy.
- **Fix**: Find the real schema name (`SHOW DATABASES;` via the `mysql` client — see "Connect to the RDS database"), then redeploy with `--parameter-overrides DBName=<the-real-name> ...` and run an instance refresh.

### Instance refresh keeps replacing instances with the same broken ones

- **Symptom**: `start-instance-refresh` reaches 50-100% but new instances still show `Target.ResponseCodeMismatch` / fail the same way the old ones did.
- **Cause**: The launch template didn't actually change the way you think it did — most commonly the `LatestAmiId` gotcha (see below), or the `deploy` that was supposed to fix things wasn't actually executed/reused stale parameter values.
- **Fix**: Before refreshing, confirm a **new** launch template version exists with the property you expect changed:
  ```bash
  aws ec2 describe-launch-template-versions \
    --launch-template-name three-tier-app-wordpress-lt \
    --region us-east-1 \
    --query "LaunchTemplateVersions[].[VersionNumber,LaunchTemplateData.ImageId,CreateTime]" \
    --output table
  ```
  If the AMI/data didn't change between versions, the deploy step needs to be redone with the correct explicit `--parameter-overrides`.

### `LatestAmiId` doesn't update just by editing the template's Default

See the dedicated "Gotcha: `LatestAmiId` doesn't auto-update just by editing the template" section above — editing `Default:` has no effect on an existing stack; you must pass `--parameter-overrides LatestAmiId=...` explicitly at least once.

### RDS snapshot restore fails: "DBName must be null when Restoring for this Engine"

- **Symptom**: `DBInstance CREATE_FAILED` with that message when `DBSnapshotIdentifier` is set.
- **Cause**: For MySQL, RDS rejects an explicit `DBName` when restoring from a snapshot — the schema name is inherited from the snapshot and can't be renamed this way.
- **Fix**: The template conditionally omits `DBName` from `DBInstance` whenever `DBSnapshotIdentifier` is set (via the `RestoreFromSnapshot` condition) — make sure this logic hasn't been reverted. The `DBName` *parameter* is still needed separately, to bake the correct value into `wp-config.php` (see the next item).
- If the stack is stuck in `ROLLBACK_COMPLETE` after this failure, delete it before retrying — a failed initial create must be deleted, not updated (see "Diagnosing a failed deploy").

### After restoring from a snapshot, `wp-config.php` has the wrong `DBName`

- **Symptom**: The "Database Error" page above, specifically right after a snapshot-restore deploy.
- **Cause**: `DBName`'s default (`appdb`) or whatever was passed doesn't match the *actual* schema name baked into the snapshot from the original deployment (e.g. it was `myappdb` there).
- **Fix**: Pass `--parameter-overrides DBName=<original-schema-name> ...` matching the snapshot's real database name — check with `aws rds describe-db-instances` history or `SHOW DATABASES;` once connected.

### After restoring from a snapshot, RDS password doesn't match `DBPassword`

- **Symptom**: Same "Error establishing a database connection" as above, right after a snapshot-restore deploy.
- **Cause**: RDS snapshots never store the master password — restoring inherits the *username* from the snapshot, but not the password. CloudFormation's `MasterUserPassword` property has no effect in this scenario.
- **Fix**: Immediately after the `DBInstance` becomes `available`, reset the password to match what you passed as `DBPassword`:
  ```bash
  aws rds modify-db-instance \
    --db-instance-identifier <db-instance-identifier> \
    --master-user-password '<same-value-as-DBPassword>' \
    --apply-immediately \
    --region us-east-1
  ```
  Also note: `DBUsername` must match the snapshot's original master username (find it with `aws rds describe-db-instances ... MasterUsername`), not just whatever default/value you'd normally use — RDS keeps the original username regardless of what's passed.

### WordPress login/internal links go to a dead URL ("This site can't be reached")

- **Symptom**: Visiting `/wp-admin` (or any internal link, redirect, permalink) goes to an old, unreachable hostname instead of the current one you're browsing from.
- **Cause**: WordPress stores its own base URL in the database (`wp_options` table, `siteurl` and `home`), set once during the setup wizard. It doesn't automatically follow infrastructure changes — this shows up in (at least) two situations:
  1. Migrating the public entry point (e.g. a single EC2 instance's public DNS → the ALB).
  2. **Recreating the stack from scratch** (e.g. after a `delete-stack`) — the new `ApplicationLoadBalancer` gets a **brand-new DNS name** every time (it's not stable across create/delete cycles), so a restored database still has the *previous* stack's ALB URL baked in, even though the underlying content is otherwise identical.
- **Fix**: Get the current URL from the stack output, then update both values via the `mysql` client:
  ```bash
  aws cloudformation describe-stacks --stack-name three-tier-app-network --region us-east-1 \
    --query "Stacks[0].Outputs[?OutputKey=='WordPressURL'].OutputValue" --output text
  ```
  ```sql
  UPDATE wp_options SET option_value="<current-WordPressURL-output>" WHERE option_name IN ("siteurl","home");
  ```
  After a fresh snapshot-restore deploy in particular, expect to need this — check it proactively rather than waiting for a broken login redirect to reveal it. **Since the Redis object cache was added, also flush it after this SQL update** — see "Direct SQL writes to `wp_options` no longer take effect on their own" under "Redis object cache" above.

### Browser times out hitting an EC2 instance's public DNS/IP directly

- **Symptom**: `ERR_CONNECTION_TIMED_OUT` / "took too long to respond" when browsing directly to an instance's public DNS name or IP on port 80.
- **Cause**: `WebServerSecurityGroup` only allows port 80 from `ALBSecurityGroup`, not the internet — by design, once the ALB was introduced. A timeout (not a clean refusal) is exactly what a security-group-level drop looks like.
- **Fix**: Use the ALB's DNS name (`WordPressURL` output), not an individual instance's address. If the instance itself may have been replaced (ASG churn, instance refresh), its old address may not even exist anymore regardless.

### Stack no longer exists ("Stack with id ... does not exist")

- **Symptom**: Any `aws cloudformation describe-stacks`/`deploy` call fails saying the stack doesn't exist, `describe-auto-scaling-groups` returns nothing.
- **Cause**: Someone ran `aws cloudformation delete-stack` (see "Delete the stack" below).
- **Fix**: Check for a final RDS snapshot before assuming data is lost — `DeletionPolicy: Snapshot` means one should exist:
  ```bash
  aws rds describe-db-snapshots --region us-east-1 --query "DBSnapshots[].[DBSnapshotIdentifier,DBInstanceIdentifier,Status,SnapshotCreateTime]" --output table
  ```
  Then redeploy fresh with `--parameter-overrides DBSnapshotIdentifier=<snapshot-id> ...` to restore the prior content instead of starting empty (see the two snapshot-restore items above for the follow-up steps that requires).

### DBeaver: "Connect timed out" / "The driver has not received any packets from the server"

- **Symptom**: DBeaver's Main-tab "Test Connection" (or actually connecting) hangs and then times out with a `Communications link failure` / no packets received at all — not a fast rejection, a full silent timeout.
- **Cause**: The SSH tunnel isn't actually active, so DBeaver is trying to reach the RDS endpoint directly from your laptop. Since `PubliclyAccessible: false`, there's no route to it from outside the VPC — that's a guaranteed silent timeout, not a fast failure. Usually caused by the **"Use SSH Tunnel" checkbox** at the top of the SSH tab not being checked, even though the fields below it are filled in.
- **Fix**: Open the connection's **SSH** tab and confirm the "Use SSH Tunnel" checkbox is checked, not just the fields populated. Use **Test Tunnel Configuration** (not "Test Connection") to isolate whether the SSH hop itself is the problem before testing the full DB connection.

### DBeaver: "SSH password authentication failed" / "Exhausted available authentication methods"

- **Symptom**: SSH tunnel test fails specifically with a *password* authentication error.
- **Cause**: The SSH tab's **Authentication Method** dropdown is set to **Password** instead of **Public Key**. Amazon Linux EC2 instances only accept the key pair for SSH — password auth is disabled entirely, so a password attempt fails immediately with nothing else to fall back to.
- **Fix**: Change **Authentication Method** to **Public Key** and point **Private Key** at the exact `.pem` file created for `KeyPairName` (e.g. `three-tier-app-key.pem`). Leave **Passphrase** blank unless one was set when the key pair was created. If it still fails, confirm the key file wasn't converted to PuTTY's `.ppk` format — DBeaver needs the original OpenSSH/PEM format from `aws ec2 create-key-pair`.

## Automated deployment via GitHub Actions

Two fully separate workflow files, split by trigger:

- [`.github/workflows/validate.yml`](.github/workflows/validate.yml) — runs on every pull request targeting `main`. Lints `cloudformation/vpc.yaml` with `cfn-lint`. No AWS credentials involved at all.
- [`.github/workflows/deploy.yml`](.github/workflows/deploy.yml) — runs on push to `main` (i.e. after a PR merges). Deploys the stack via GitHub OIDC.

**Why two separate files instead of one workflow with two jobs** (which is how this started): each needed its own `concurrency` scope. `deploy` correctly queues behind other deploys (`group: cloudformation-deploy, cancel-in-progress: false` — never skip/cancel a real infrastructure change). But a single shared `concurrency` group across both jobs meant a PR's lint run would needlessly queue behind an in-progress production deploy too, despite `validate` never touching AWS at all. Separate files, separate groups: `validate` uses `group: cfn-lint-${{ github.event.pull_request.number }}, cancel-in-progress: true` instead — pushing several commits to the same PR quickly cancels the older, now-superseded lint run rather than queuing behind it.

Authentication for `deploy` uses **GitHub OIDC** — no long-lived AWS access keys stored anywhere in this repo. GitHub Actions requests a short-lived identity token and assumes `GitHubActionsDeployRole` directly; AWS trusts the request only because that role's trust policy checks the token's `sub` claim against this exact repo and branch.

**Why `validate` doesn't also use OIDC**: a `pull_request`-triggered OIDC token has a different `sub` claim shape than a `push`-triggered one (`repo:<org>/<repo>:pull_request` vs. `repo:<org>@<id>/<repo>@<id>:ref:refs/heads/main`), which `GitHubActionsDeployRole`'s trust policy deliberately doesn't authorize. Rather than widen that trust policy to also cover PR runs — which would mean any PR, in principle, could carry AWS credentials capable of deploying this stack — `validate` uses `cfn-lint` instead, which needs no cloud credentials at all. Safer default for a repo that takes PRs.

### Branch protection on `main`

Configured directly via the GitHub API (`gh api repos/<org>/<repo>/branches/main/protection`, not through the workflow files themselves):

- **Pull request required before merge** — direct pushes to `main` are rejected by GitHub itself, not just by convention. `required_approving_review_count: 0`, since this is a solo-maintained repo and requiring even one approval would make the repo's own owner unable to ever merge their own PR.
- **Required status check**: `Validate CloudFormation template (cfn-lint)` (the job name in `validate.yml`) must pass before a PR can be merged — a red `cfn-lint` result makes the merge button unavailable, not just a warning badge.
- **`strict: true`** (branch must be up to date before merging) — forces a PR to be rebased onto the current `main` tip before merge is allowed. This is exactly the check that would have caught the PR #1/#2 merge conflict *before* merge was even permitted, rather than after (see "PR checks stop running / stuck pending" in Troubleshooting for what happened without it).
- **`enforce_admins: true`** — applies even to the repository owner. Without this, the whole rule is optional for whoever needs it least to actually follow.
- Force-pushes and deletion of `main` are also blocked, as a side effect of enabling any branch protection at all.

**Gotcha to watch for if you ever rename the lint job or restructure the workflow files**: the required status check is matched by exact job name (`context` in the GitHub API), not by file path. If `validate.yml`'s job `name:` ever changes, update the branch protection rule's required check to match — otherwise every future PR becomes permanently unmergeable (including the one meant to fix it), since `enforce_admins: true` leaves no bypass.

```bash
# check current branch protection state:
gh api repos/<org>/<repo>/branches/main/protection

# update the required status check name if the job name ever changes:
gh api repos/<org>/<repo>/branches/main/protection -X PUT --input - <<'EOF'
{
  "required_status_checks": {"strict": true, "checks": [{"context": "<new-job-name>"}]},
  "enforce_admins": true,
  "required_pull_request_reviews": {"required_approving_review_count": 0},
  "restrictions": null
}
EOF
```

### One-time AWS-side setup (already done for this stack)

`GitHubActionsDeployRole` (`three-tier-app-pipeline-deploy-role`) is defined in its own stack, **`cloudformation/pipeline.yaml`** (stack name `three-tier-app-pipeline`), deployed **manually by an admin, never by the pipeline** — see "Why the deploy role lives in its own stack" below. It's parameterized by `GitHubOrg`/`GitHubOrgId`/`GitHubRepo`/`GitHubRepoId`/`GitHubBranch` (defaults: `bdahiya2007` / `5674538` / this repo's name / this repo's numeric ID / `main`). It trusts the **existing** account-wide GitHub OIDC provider (`token.actions.githubusercontent.com`) — that provider is a one-per-AWS-account resource, so if your account already has one from another project, this template does not (and must not) try to create a duplicate; it only adds a new role that references the existing provider by ARN.

The pipeline stack also owns the AWS Backup service role and `AppRoleBoundary` (a permissions boundary), and exports both ARNs for the app stack to import. **Deploy it before the app stack**, since the app stack's `Fn::ImportValue`s fail without it.

**`GitHubRepoId` has no default and must be supplied** — it's specific to whatever repo you're deploying from. Get it with:

```bash
gh api repos/<your-github-username>/<your-repo-name> --jq '.id'
```

(and `gh api users/<your-github-username> --jq '.id'` for `GitHubOrgId`, if different from the default above).

A workflow can't assume a role that doesn't exist yet, and by design it can't modify this stack either. So create or update it manually, with your own admin credentials:

```bash
aws cloudformation deploy \
  --template-file cloudformation/pipeline.yaml \
  --stack-name three-tier-app-pipeline \
  --region us-east-1 \
  --capabilities CAPABILITY_NAMED_IAM \
  --parameter-overrides GitHubRepo=<your-repo-name> GitHubRepoId=<your-repo-id>
```

After that, get the role's ARN from the stack output:

```bash
aws cloudformation describe-stacks \
  --stack-name three-tier-app-pipeline \
  --region us-east-1 \
  --query "Stacks[0].Outputs[?OutputKey=='DeployRoleArn'].OutputValue" \
  --output text
```

Any change to the deploy role's permissions (for example, a new AWS service the app stack starts using) is a `pipeline.yaml` change that **you** deploy with this command after the PR merges. The pipeline won't do it for you.

### Required repository secrets

Set these under **Settings → Secrets and variables → Actions → Repository secrets**:

| Secret | Value |
|---|---|
| `AWS_DEPLOY_ROLE_ARN` | The pipeline stack's `DeployRoleArn` output from above, e.g. `arn:aws:iam::<account-id>:role/three-tier-app-pipeline-deploy-role` |
| `DB_PASSWORD` | Value for the `DBPassword` parameter (8-41 chars, no `/`, `@`, `"`, `'`, `\`, or spaces) |
| `KEY_PAIR_NAME` | Name of an existing EC2 key pair in `us-east-1` (`KeyPairName` parameter) |

No AWS access key/secret key secrets exist at all with this approach — a role ARN isn't a credential by itself (nothing can be done with it without also passing GitHub's OIDC trust check), so it doesn't need the same secrecy as a real access key, though there's no harm in keeping it as a secret anyway.

### IAM permissions on `GitHubActionsDeployRole`

Scoped deliberately, not a broad managed policy:
- **CloudFormation** actions restricted to this one stack's ARN (`stack/three-tier-app-network/*`); `ValidateTemplate` is separate since that action has no resource-level permission support.
- **EC2, Auto Scaling, RDS, ELBv2, EFS, ElastiCache, AWS Backup, Logs, CloudWatch, Lambda, SSM, CloudFront, WAFv2, ACM**: action list scoped to only what a deploy needs (not `service:*` wildcards, except where AWS groups related actions like `autoscaling:*`/`rds:*`/`elasticfilesystem:*`/`elasticache:*`/`backup:*`/`cloudfront:*`/`wafv2:*`/`acm:*` themselves) — but on `Resource: "*"`, since most of these create/describe/modify actions genuinely don't support resource-level ARN restriction in AWS's own IAM implementation (a documented AWS limitation, not a shortcut here). ACM specifically has no such restriction to apply anyway: a certificate's ARN doesn't exist yet at policy-write time, and DNS-validated certs are typically single-use per domain.
- **Route 53**: restricted to the one hosted zone this stack adds a record into (`arn:aws:route53:::hostedzone/<id>`), not `route53:*` on every zone in the account — unlike most of the list above, Route 53 record actions genuinely do support resource-level ARN restriction, so there was no reason not to use it. `route53:GetChange` is the one exception (`Resource: "*"`) since change IDs aren't scoped to a zone.
- **Secrets Manager**: create, read, update and delete only on `secret:three-tier-app-*` (the DB master secret and the origin-verify secret). `GetRandomPassword` (used by `GenerateSecretString`) is `Resource: "*"` because it has no resource-level scoping. The deploy role needs `GetSecretValue` because CloudFormation resolves `{{resolve:secretsmanager:...}}` references with the caller's credentials.
- **S3**: restricted to bucket names starting with `three-tier-app-network-` (this stack's naming convention for the ALB logs bucket).
- **IAM**: the tightest of all, since over-broad IAM permissions on a CI role are a privilege-escalation risk. See the next section.

### Why the deploy role lives in its own stack

**Found in a security review:** the deploy role used to live in `vpc.yaml`, and its IAM statement allowed `iam:CreateRole`/`PutRolePolicy`/`AttachRolePolicy` on `role/three-tier-app-*`. That pattern matches the deploy role's own name, and it had to: CloudFormation updated the role's policy using the role's own credentials. So anything holding its credentials could attach `AdministratorAccess` to itself, or create a new `three-tier-app-*` role with any trust policy and any permissions. **A role that deploys its own permissions can always escalate them**, and tightening the conditions doesn't fix that. The fix is structural, the same pattern as CDK's bootstrap stack:

- **The role moved to `pipeline.yaml`**, a separate stack only an admin deploys. `vpc.yaml` no longer contains it, and an explicit `Deny iam:*` on its own ARN (and on `policy/three-tier-app-pipeline-*`) overrides every Allow.
- **Permission-granting IAM actions require `AppRoleBoundary`.** `CreateRole`, `PutRolePolicy`, `AttachRolePolicy` and `PutRolePermissionsBoundary` only succeed on a role whose permissions boundary is `three-tier-app-pipeline-app-role-boundary` (the `iam:PermissionsBoundary` condition). The boundary allows only what the app's own roles need: the CloudWatch agent's actions, log retention, and reading `three-tier-app-*` secrets. Even an admin policy attached to such a role yields nothing more. `iam:DeleteRolePermissionsBoundary` is explicitly denied, so the cap can't be removed.
- **The AWS Backup service role moved to `pipeline.yaml` as well.** Its AWS-managed policy (EC2/RDS/KMS/DynamoDB/…) is far broader than the boundary, so the pipeline must not be able to create or edit a role like it. The app stack imports its ARN, and the pipeline can only `PassRole`/`GetRole` it.
- **Non-escalating IAM actions** (read, tag, delete, detach, instance-profile plumbing, `PassRole`) remain on `role/three-tier-app-*`. Every role they could touch or pass is capped by the boundary or owned by the pipeline stack.

**Residual risk, knowingly accepted:** anyone who can merge to `main` *and* approve the `production` deployment can still change what the app stack does within these limits. That's what the pipeline is for, and branch protection plus the approval gate cover it. The pipeline stack's own changes need your admin credentials.

### First deploy after the move: two failures and a stuck rollback

The first deploy with the new role (re-run after an earlier attempt ran before the pipeline stack existed, so `Fn::ImportValue` failed) hit two problems:

- **`BackupSelection` replacement failed:** "Backup selection with the same selection document already exists". Switching `IamRoleArn` forces a replacement, and CloudFormation creates the new selection *before* deleting the old one. With the same `SelectionName` and contents, AWS Backup rejects it as a duplicate. **Fix:** a new `SelectionName` (`-v2`).
- **The rollback then failed (`UPDATE_ROLLBACK_FAILED`):** rolling back meant removing the just-added boundary from `CloudWatchAgentRole`/`RdsLogRetentionFunctionRole`, and the deploy role is explicitly denied `iam:DeleteRolePermissionsBoundary`. That's by design, since removing the boundary is how you'd escape it. It also meant the boundary *had* been applied successfully, which confirmed the `iam:PermissionsBoundary` condition works.
- **Recovery (admin credentials, since the deploy role has no `ContinueUpdateRollback`):**
  ```bash
  aws cloudformation continue-update-rollback --stack-name three-tier-app-network --region us-east-1 \
    --resources-to-skip CloudWatchAgentRole RdsLogRetentionFunctionRole
  ```
  Skipping keeps the boundary on both roles, which is safer than removing it. CloudFormation records them as rolled back, and the next deploy re-applies the same boundary as a no-op.
- **General lesson:** an explicit Deny on an "undo" action also blocks CloudFormation's automatic undo of that change. Any future rollback of a change that *adds* a boundary will need this same admin `continue-update-rollback` step.

### What `validate.yml` does (pull requests)

1. Checks out the repo.
2. Installs `cfn-lint` (Python, via `pip`).
3. Runs `cfn-lint cloudformation/vpc.yaml cloudformation/pipeline.yaml`.

No AWS credentials, no `deploy` step — this job's only purpose is to catch template-level mistakes before merge. `cfn-lint`'s exit code is non-zero for warnings too, not just errors, so it fails the check on `W`-level findings — see "cfn-lint W3005 / W1011 findings" in Troubleshooting for the two patterns already hit and how they were resolved.

### What `deploy.yml` does (push to `main`)

1. Checks out the repo.
2. Requests a GitHub OIDC token and assumes `AWS_DEPLOY_ROLE_ARN` (`aws-actions/configure-aws-credentials`, `role-to-assume` instead of static keys) — requires the job-level `permissions: id-token: write`.
3. Runs `aws cloudformation validate-template` (fails fast on a syntax error before touching any real resources — a second, AWS-API-based check on top of what `cfn-lint` already did in the PR).
4. Runs `aws cloudformation deploy` with `DBPassword`/`KeyPairName` from secrets — every other parameter is omitted, so CloudFormation reuses the stack's current values for them (same "reuse previous value" behavior as the manual `deploy` commands throughout this file).
5. Prints the stack outputs.

`--no-fail-on-empty-changeset` is important here: most pushes to `main` won't touch `cloudformation/vpc.yaml` at all (e.g. a `Deployment.md` edit), and without that flag `aws cloudformation deploy` exits non-zero when there's nothing to actually change — which would mark the workflow as failed for completely unrelated commits.

### Manual approval gate before every deploy

The `deploy` job in `deploy.yml` targets a GitHub Environment named `production`, configured (via the GitHub API, not in this repo's files — environment protection rules aren't expressible in workflow YAML) with `bdahiya2007` as a required reviewer. A push to `main` still triggers the workflow run immediately, but the `deploy` job **pauses before running any steps** until explicitly approved from the Actions tab (the run's page → "Review deployments" → Approve) — a separate checkpoint from the PR merge itself, not a replacement for it. `prevent_self_review` is left at its default (`false`), since a solo maintainer needs to be able to approve their own deployments.

**Why add this on top of branch protection**: branch protection gates what can reach `main` (PR + passing `cfn-lint`), but nothing previously gated the moment `main` actually gets pushed to AWS — merging *was* deploying. This adds a genuine pause between "the change is merged" and "the change is live," useful as a last "did I actually mean to ship this right now" check, independent of whether the PR review itself was thorough.

**Real regression this caused**: adding `environment: production` changed the OIDC `sub` claim the job presents (`...:environment:production` instead of `...:ref:refs/heads/main`), which broke role assumption entirely the next time `main` was pushed to — see "GitHub Actions OIDC breaks again after adding an `environment:` to a job" in Troubleshooting for the fix. Caught via CloudTrail, not assumed; fixed by listing both `sub` formats in the trust policy.

### Limitations / things to know before relying on this for anything beyond a portfolio project

- **No snapshot-restore or first-time-create handling** — this workflow assumes the stack already exists and is doing routine updates. The snapshot-restore parameters (`DBSnapshotIdentifier`, etc.) aren't wired into it; run that manually per the "Deploy restoring the database from a snapshot" section if ever needed.
- **The trust policy is branch-specific** — only pushes on `refs/heads/main` (via `GitHubBranch`, default `main`) can assume this role. A workflow run from a different branch, a fork, or a pull_request-triggered event (different `sub` claim shape) will get `AccessDenied` on the OIDC assume-role step, by design.

## Delete the stack

Both RDS instances have **`DeletionProtection: true`**, so a plain `delete-stack` fails on them. Turn it off first. It's a deliberate extra step, the same guard that stops an accidental `delete-stack` from removing the database:

```bash
for id in $(aws cloudformation describe-stack-resources --stack-name three-tier-app-network --region us-east-1 \
  --query "StackResources[?ResourceType=='AWS::RDS::DBInstance'].PhysicalResourceId" --output text); do
  aws rds modify-db-instance --db-instance-identifier $id --no-deletion-protection --apply-immediately --region us-east-1
done
```

This drifts from the template until the stack is gone, which doesn't matter because it's being deleted. If you change your mind, the next deploy sets it back to `true`.

Delete the app stack first. The pipeline stack can't be deleted while the app stack still imports its exports.

```bash
aws cloudformation delete-stack \
  --stack-name three-tier-app-network \
  --region us-east-1
aws cloudformation wait stack-delete-complete --stack-name three-tier-app-network --region us-east-1

# only if you're done with CI/CD for this account too:
aws cloudformation delete-stack \
  --stack-name three-tier-app-pipeline \
  --region us-east-1
```

The RDS instance has `DeletionPolicy: Snapshot`, so deleting the stack takes a final snapshot instead of destroying the database outright.
