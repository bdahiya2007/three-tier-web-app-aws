# Deployment

Commands for deploying the full CloudFormation stack for the three-tier web app: a VPC spanning two Availability Zones, a MySQL RDS instance in the private subnet(s), an Application Load Balancer + Auto Scaling Group (2-3 instances by default) launching WordPress EC2 instances (Amazon Linux 2023, PHP 8.3, Apache) across two public subnets, an EFS file system mounted at `wp-content` on every instance so uploads/themes/plugins are shared across the group, a CloudWatch dashboard (EC2/RDS CPU, ALB request count), and logging (ALB access logs to S3, instance logs + RDS error log to CloudWatch Logs). Assumes AWS CLI v2 is installed and credentials are configured (`aws configure` or an active SSO/profile session) with permission to create VPC, RDS, EC2, ELBv2, EFS, IAM, S3, CloudWatch, and Auto Scaling resources.

**Every `deploy` command below needs `--capabilities CAPABILITY_NAMED_IAM`** — the stack creates a named IAM role (`CloudWatchAgentRole`, for the CloudWatch agent on each instance), and CloudFormation refuses to create/update IAM resources without this explicit acknowledgment. Omitting it fails with `Requires capabilities : [CAPABILITY_NAMED_IAM]`.

The `DBPassword` parameter has no default and must be supplied at deploy time (8-41 characters, no `/`, `@`, `"`, or spaces).

If your account is on the RDS free tier, `DBBackupRetentionPeriod` must stay at its default (`1`) — a higher value fails with `The specified backup retention period exceeds the maximum available to free tier customers`.

`KeyPairName` also has no default and must reference an EC2 key pair that already exists in `us-east-1` (see "Create a key pair" below).

`SSHLocationCidr` defaults to `0.0.0.0/0` (open to the internet). Restrict it to your own IP for anything beyond a quick test, e.g. `--parameter-overrides SSHLocationCidr=$(curl -s ifconfig.me)/32 ...`.

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

Any change that affects the launch template — `DBPassword`, `LatestAmiId`, `WebServerInstanceType`, or editing the `UserData` script itself (e.g. the PHP version installed) — creates a **new launch template version** when you deploy, but does **not** touch instances that are already running. You must explicitly tell the Auto Scaling Group to replace them:

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

Omitted parameters (`DBPassword`, `KeyPairName`, `GitHubRepo`, `GitHubRepoId`, etc.) reuse their current stored values automatically — no need to re-supply them just to change the ASG size. `AsgMaxSize` (default `3`) is left alone either way, so the group can still burst up under load even while scaled down to a 1-instance floor.

Scaling down to 1 removes the multi-AZ redundancy that scaling to 2+ provides — acceptable for a deliberately idle period, not for normal operation. Scaling to `0` is also possible (maximum savings, but the ALB returns `503` to any visitor until scaled back up, and a scale-up from `0` means every instance is a cold boot — full `UserData` bootstrap, EFS mount, WordPress install — rather than most instances already being warm).

## Check stack status

```bash
aws cloudformation describe-stacks \
  --stack-name three-tier-app-network \
  --region us-east-1 \
  --query "Stacks[0].StackStatus"
```

## View stack outputs (VPC ID, subnet IDs, route table IDs, RDS endpoint, ALB DNS name, EFS file system ID, CloudWatch dashboard URL, ALB logs bucket, log group names, WordPress URL)

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

Once the stack finishes and each instance's `UserData` script completes (allow a few extra minutes after `UPDATE_COMPLETE`/`CREATE_COMPLETE` for WordPress to install and the ALB target group health checks to pass), open the `WordPressURL` output value in a browser to run the WordPress setup wizard.

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

## Troubleshooting

Every issue actually hit while building and operating this stack, with symptom → cause → fix. Check here first before re-diagnosing from scratch.

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
  After a fresh snapshot-restore deploy in particular, expect to need this — check it proactively rather than waiting for a broken login redirect to reveal it.

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

[`.github/workflows/deploy.yml`](.github/workflows/deploy.yml) deploys the stack automatically on every push to `main`. Authentication uses **GitHub OIDC** — no long-lived AWS access keys stored anywhere in this repo. GitHub Actions requests a short-lived identity token and assumes `GitHubActionsDeployRole` directly; AWS trusts the request only because that role's trust policy checks the token's `sub` claim against this exact repo and branch.

### One-time AWS-side setup (already done for this stack)

`GitHubActionsDeployRole` is defined in `cloudformation/vpc.yaml` itself, parameterized by `GitHubOrg`/`GitHubOrgId`/`GitHubRepo`/`GitHubRepoId`/`GitHubBranch` (defaults: `bdahiya2007` / `5674538` / this repo's name / this repo's numeric ID / `main`). It trusts the **existing** account-wide GitHub OIDC provider (`token.actions.githubusercontent.com`) — that provider is a one-per-AWS-account resource, so if your account already has one from another project, this template does not (and must not) try to create a duplicate; it only adds a new role that references the existing provider by ARN.

**`GitHubRepoId` has no default and must be supplied** — it's specific to whatever repo you're deploying from. Get it with:

```bash
gh api repos/<your-github-username>/<your-repo-name> --jq '.id'
```

(and `gh api users/<your-github-username> --jq '.id'` for `GitHubOrgId`, if different from the default above).

Since a workflow can't assume a role that doesn't exist yet, this role has to be created by a manual, already-authenticated `deploy` at least once (chicken-and-egg — CI can't bootstrap its own trust relationship):

```bash
aws cloudformation deploy \
  --template-file cloudformation/vpc.yaml \
  --stack-name three-tier-app-network \
  --region us-east-1 \
  --capabilities CAPABILITY_NAMED_IAM \
  --parameter-overrides GitHubRepo=<your-repo-name> GitHubRepoId=<your-repo-id> DBPassword=<your-db-password> KeyPairName=<your-key-pair-name>
```

After that, get the role's ARN from the stack output:

```bash
aws cloudformation describe-stacks \
  --stack-name three-tier-app-network \
  --region us-east-1 \
  --query "Stacks[0].Outputs[?OutputKey=='GitHubActionsDeployRoleArn'].OutputValue" \
  --output text
```

### Required repository secrets

Set these under **Settings → Secrets and variables → Actions → Repository secrets**:

| Secret | Value |
|---|---|
| `AWS_DEPLOY_ROLE_ARN` | The `GitHubActionsDeployRoleArn` output from above, e.g. `arn:aws:iam::<account-id>:role/three-tier-app-github-actions-deploy-role` |
| `DB_PASSWORD` | Value for the `DBPassword` parameter (8-41 chars, no `/`, `@`, `"`, or spaces) |
| `KEY_PAIR_NAME` | Name of an existing EC2 key pair in `us-east-1` (`KeyPairName` parameter) |

No AWS access key/secret key secrets exist at all with this approach — a role ARN isn't a credential by itself (nothing can be done with it without also passing GitHub's OIDC trust check), so it doesn't need the same secrecy as a real access key, though there's no harm in keeping it as a secret anyway.

### IAM permissions on `GitHubActionsDeployRole`

Scoped deliberately, not a broad managed policy:
- **CloudFormation** actions restricted to this one stack's ARN (`stack/three-tier-app-network/*`); `ValidateTemplate` is separate since that action has no resource-level permission support.
- **EC2, Auto Scaling, RDS, ELBv2, EFS, Logs, CloudWatch, Lambda, SSM**: action list scoped to only what a deploy needs (not `service:*` wildcards, except where AWS groups related actions like `autoscaling:*`/`rds:*`/`elasticfilesystem:*` themselves) — but on `Resource: "*"`, since most of these create/describe/modify actions genuinely don't support resource-level ARN restriction in AWS's own IAM implementation (a documented AWS limitation, not a shortcut here).
- **S3**: restricted to bucket names starting with `three-tier-app-network-` (this stack's naming convention for the ALB logs bucket).
- **IAM**: the tightest of all, since over-broad IAM permissions on a CI role is a privilege-escalation risk — restricted to role/instance-profile ARNs starting with `three-tier-app-` (this stack's own resources only, including the role itself, so future deploys can still update its own permissions).

### What the workflow does

1. Checks out the repo.
2. Requests a GitHub OIDC token and assumes `AWS_DEPLOY_ROLE_ARN` (`aws-actions/configure-aws-credentials`, `role-to-assume` instead of static keys) — requires the job-level `permissions: id-token: write`.
3. Runs `aws cloudformation validate-template` (fails fast on a syntax error before touching any real resources).
4. Runs `aws cloudformation deploy` with `DBPassword`/`KeyPairName` from secrets — every other parameter is omitted, so CloudFormation reuses the stack's current values for them (same "reuse previous value" behavior as the manual `deploy` commands throughout this file).
5. Prints the stack outputs.

`--no-fail-on-empty-changeset` is important here: most pushes to `main` won't touch `cloudformation/vpc.yaml` at all (e.g. a `Deployment.md` edit), and without that flag `aws cloudformation deploy` exits non-zero when there's nothing to actually change — which would mark the workflow as failed for completely unrelated commits.

### Limitations / things to know before relying on this for anything beyond a portfolio project

- **No change-set review step** — unlike the manual workflow documented above (create → review → execute), this deploys directly on every push with no human review gate. Fine for solo/learning use; for a team, add a required PR review before merge to `main`, or switch this workflow to trigger on a tag/manual `workflow_dispatch` instead of every push.
- **No snapshot-restore or first-time-create handling** — this workflow assumes the stack already exists and is doing routine updates. The snapshot-restore parameters (`DBSnapshotIdentifier`, etc.) aren't wired into it; run that manually per the "Deploy restoring the database from a snapshot" section if ever needed.
- **No instance refresh** — per "Update running instances after a launch template change" above, a stack update alone doesn't replace already-running EC2 instances. This workflow doesn't trigger one automatically; if a change needs it (AMI, `UserData`, IAM instance profile, etc.), run `aws autoscaling start-instance-refresh` manually afterward.
- **The trust policy is branch-specific** — only pushes on `refs/heads/main` (via `GitHubBranch`, default `main`) can assume this role. A workflow run from a different branch, a fork, or a pull_request-triggered event (different `sub` claim shape) will get `AccessDenied` on the OIDC assume-role step, by design.

## Delete the stack

```bash
aws cloudformation delete-stack \
  --stack-name three-tier-app-network \
  --region us-east-1
```

The RDS instance has `DeletionPolicy: Snapshot`, so deleting the stack takes a final snapshot instead of destroying the database outright.
