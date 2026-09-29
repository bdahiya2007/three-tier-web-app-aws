#!/usr/bin/env bash
# Tear the app stack down to save cost, and rebuild it later from its final DB snapshot.
#
#   scripts/stack.sh status                  what exists now, what's billable
#   scripts/stack.sh down  [--yes] [--dry-run]
#   scripts/stack.sh up    [--snapshot ID] [--ssh-key PATH] [--dry-run]
#
# down: saves the stack's parameters, turns off RDS deletion protection, deletes the
#       read replica, empties the S3 buckets and the AWS Backup vault (both block
#       stack deletion), deletes the stack (RDS keeps a final snapshot via its
#       DeletionPolicy), frees the secret names for reuse, then verifies nothing
#       billable is left. The pipeline stack (IAM only, free) is kept.
# up:   recreates the stack from the newest final snapshot with the saved
#       parameters, sets the restored DB's password to the new secret as soon as
#       RDS is up (snapshots keep the old password), and verifies the site - and,
#       with --ssh-key, a real MySQL login to both endpoints.
#
# See "Tear down and rebuild (cost saving)" in Deployment.md.

set -euo pipefail

STACK=three-tier-app-network
PIPELINE_STACK=three-tier-app-pipeline
REGION=us-east-1
TEMPLATE="$(cd "$(dirname "$0")/.." && pwd)/cloudformation/vpc.yaml"
STATE_DIR="$HOME/.three-tier-app"          # outside the repo: holds your SSH source IP
PARAMS_FILE="$STATE_DIR/$STACK-params.json"

DRY_RUN=false; YES=false; SNAPSHOT=""; SSH_KEY=""
aws() { command aws --region "$REGION" "$@"; }
say() { printf '\n==> %s\n' "$*"; }
run() { if $DRY_RUN; then printf '    [dry-run] %s\n' "$*"; else "$@"; fi; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

stack_status() { aws cloudformation describe-stacks --stack-name "$1" --query 'Stacks[0].StackStatus' --output text 2>/dev/null || echo NONE; }
resource_id() { aws cloudformation describe-stack-resource --stack-name "$STACK" --logical-resource-id "$1" \
                  --query StackResourceDetail.PhysicalResourceId --output text 2>/dev/null || true; }
output() { aws cloudformation describe-stacks --stack-name "$STACK" \
             --query "Stacks[0].Outputs[?OutputKey=='$1'].OutputValue" --output text 2>/dev/null || true; }

billable_leftovers() {
  # Anything from this stack that would still cost money. Empty output = clean.
  aws rds describe-db-instances --query "DBInstances[?starts_with(DBInstanceIdentifier,'$STACK')].['RDS',DBInstanceIdentifier,DBInstanceStatus]" --output text
  aws elbv2 describe-load-balancers --query "LoadBalancers[?LoadBalancerName=='three-tier-app-alb'].['ALB',LoadBalancerName]" --output text 2>/dev/null || true
  aws ec2 describe-instances --filters Name=tag:Name,Values=three-tier-app-wordpress Name=instance-state-name,Values=pending,running,stopping,stopped \
    --query "Reservations[].Instances[].['EC2',InstanceId,State.Name]" --output text
  aws elasticache describe-cache-clusters --query "CacheClusters[?starts_with(CacheClusterId,'three-tier-app')].['ElastiCache',CacheClusterId,CacheClusterStatus]" --output text
  aws efs describe-file-systems --query "FileSystems[?Name=='three-tier-app-efs'].['EFS',FileSystemId,LifeCycleState]" --output text
  aws ec2 describe-addresses --query "Addresses[?Tags[?Value=='$STACK']].['EIP',PublicIp]" --output text
  command aws cloudfront list-distributions --query "DistributionList.Items[?contains(to_string(Aliases.Items),'blog.securecloudengineers.com')].['CloudFront',Id,Status]" --output text 2>/dev/null || true
}

latest_final_snapshot() {
  aws rds describe-db-snapshots --snapshot-type manual \
    --query "reverse(sort_by(DBSnapshots[?starts_with(DBSnapshotIdentifier,'$STACK-dbinstance') && Status=='available'],&SnapshotCreateTime))[0].DBSnapshotIdentifier" --output text
}

cmd_status() {
  say "Stacks"
  echo "    $STACK: $(stack_status "$STACK")"
  echo "    $PIPELINE_STACK: $(stack_status "$PIPELINE_STACK")"
  say "Billable resources from this stack"
  billable_leftovers | sed 's/^/    /'
  say "Final DB snapshots (what 'up' restores from)"
  aws rds describe-db-snapshots --snapshot-type manual \
    --query "DBSnapshots[?starts_with(DBSnapshotIdentifier,'$STACK-dbinstance')].[DBSnapshotIdentifier,SnapshotCreateTime,AllocatedStorage]" --output text \
    | sed 's/^/    /' | grep . || echo "    (none - 'down' creates one)"
  [ -f "$PARAMS_FILE" ] && echo "    saved parameters: $PARAMS_FILE" || echo "    no saved parameters yet"
}

cmd_down() {
  [ "$(stack_status "$STACK")" = NONE ] && die "$STACK doesn't exist - nothing to delete"
  local account; account=$(aws sts get-caller-identity --query Account --output text)

  say "Plan: delete $STACK in $account/$REGION (site goes offline; RDS keeps a final snapshot)"
  echo "    Lost with the stack: AWS Backup recovery points, EFS (wp-content: uploads + manually"
  echo "    installed plugins not in UserData), logs in stack-owned log groups, ALB access logs."
  echo "    Kept: the final RDS snapshot, the pipeline stack, content/ in git."
  if ! $YES && ! $DRY_RUN; then
    read -r -p "    Type the stack name to confirm: " answer
    [ "$answer" = "$STACK" ] || die "confirmation didn't match - nothing changed"
  fi

  say "1/8 Saving stack parameters to $PARAMS_FILE"
  local primary replica
  primary=$(resource_id DBInstance); replica=$(resource_id DBReadReplica)
  local db_user; db_user=$(aws rds describe-db-instances --db-instance-identifier "$primary" --query 'DBInstances[0].MasterUsername' --output text)
  if ! $DRY_RUN; then
    mkdir -p "$STATE_DIR"; chmod 700 "$STATE_DIR"
    aws cloudformation describe-stacks --stack-name "$STACK" --query 'Stacks[0].Parameters' --output json \
      | python3 -c "import json,sys; p={x['ParameterKey']:x['ParameterValue'] for x in json.load(sys.stdin) if x['ParameterValue']!='****'}; p['DBUsername']=sys.argv[1]; print(json.dumps(p,indent=2,sort_keys=True))" "$db_user" \
      > "$PARAMS_FILE"
    chmod 600 "$PARAMS_FILE"
  fi
  $DRY_RUN && echo "    [dry-run] would save them (DBUsername: $db_user, read from RDS since it's NoEcho)" \
           || echo "    saved (NoEcho values like DBUsername are read from RDS instead)"

  say "2/8 Turning off RDS deletion protection"
  for db in "$primary" "$replica"; do
    [ -n "$db" ] && run aws rds modify-db-instance --db-instance-identifier "$db" --no-deletion-protection --apply-immediately --query 'DBInstance.DBInstanceIdentifier' --output text
  done
  $DRY_RUN || aws rds wait db-instance-available --db-instance-identifier "$primary"

  say "3/8 Deleting the read replica (replicas can't take a final snapshot)"
  if [ -n "$replica" ]; then
    run aws rds delete-db-instance --db-instance-identifier "$replica" --skip-final-snapshot --query 'DBInstance.DBInstanceStatus' --output text
    $DRY_RUN || aws rds wait db-instance-deleted --db-instance-identifier "$replica"
  fi

  say "4/8 Emptying S3 buckets (CloudFormation can't delete non-empty buckets)"
  for b in $(resource_id ALBLogsBucket) $(resource_id CfnArtifactsBucket); do
    run aws s3 rm "s3://$b" --recursive --only-show-errors
  done

  say "5/8 Deleting AWS Backup recovery points (a non-empty vault blocks deletion)"
  local vault; vault=$(resource_id BackupVault)
  local points; points=$(aws backup list-recovery-points-by-backup-vault --backup-vault-name "$vault" --query 'RecoveryPoints[].RecoveryPointArn' --output text)
  echo "    $(echo "$points" | wc -w) recovery point(s) in $vault"
  for rp in $points; do run aws backup delete-recovery-point --backup-vault-name "$vault" --recovery-point-arn "$rp"; done
  if ! $DRY_RUN; then
    for _ in $(seq 60); do
      [ "$(aws backup list-recovery-points-by-backup-vault --backup-vault-name "$vault" --query 'length(RecoveryPoints)' --output text)" = 0 ] && break
      sleep 10
    done
  fi

  say "6/8 Deleting stack $STACK (CloudFront alone takes ~15 min; expect 25-40 min total)"
  run aws cloudformation delete-stack --stack-name "$STACK"
  if ! $DRY_RUN && ! aws cloudformation wait stack-delete-complete --stack-name "$STACK"; then
    echo "    first attempt failed - usually new ALB logs landed after emptying. Resources that failed:"
    aws cloudformation describe-stack-events --stack-name "$STACK" --query "StackEvents[?ResourceStatus=='DELETE_FAILED'].[LogicalResourceId,ResourceStatusReason]" --output text | head -5 | sed 's/^/      /'
    for b in $(resource_id ALBLogsBucket) $(resource_id CfnArtifactsBucket); do aws s3 rm "s3://$b" --recursive --only-show-errors || true; done
    aws cloudformation delete-stack --stack-name "$STACK"
    aws cloudformation wait stack-delete-complete --stack-name "$STACK" || die "stack deletion failed twice - see the stack's events in the console"
  fi

  say "7/8 Freeing secret names (deleted secrets are otherwise reserved for 30 days, blocking 'up')"
  for s in three-tier-app-db-master three-tier-app-origin-verify; do
    if aws secretsmanager describe-secret --secret-id "$s" >/dev/null 2>&1; then
      run aws secretsmanager delete-secret --secret-id "$s" --force-delete-without-recovery --query Name --output text
    fi
  done

  say "8/8 Verifying"
  $DRY_RUN && { echo "    [dry-run] would check: stack gone, no billable leftovers, final snapshot present"; return; }
  [ "$(stack_status "$STACK")" = NONE ] && echo "    stack: deleted" || die "stack still exists: $(stack_status "$STACK")"
  local left; left=$(billable_leftovers)
  [ -z "$left" ] && echo "    billable leftovers: none" || { echo "    STILL PRESENT (check these):"; echo "$left" | sed 's/^/      /'; }
  echo "    final snapshot: $(latest_final_snapshot)"
  echo "    parameters: $PARAMS_FILE"
  echo "    Idle cost is now roughly the snapshot's storage (cents/month). Rebuild with: scripts/stack.sh up"
}

cmd_up() {
  [ "$(stack_status "$STACK")" = NONE ] || die "$STACK already exists ($(stack_status "$STACK")) - 'up' only rebuilds a deleted stack"
  [ "$(stack_status "$PIPELINE_STACK")" != NONE ] || die "$PIPELINE_STACK is missing - deploy it first (Deployment.md, 'Deploy the stack')"
  [ -f "$PARAMS_FILE" ] || die "no saved parameters at $PARAMS_FILE - 'down' writes them; see Deployment.md to rebuild by hand"
  local account; account=$(aws sts get-caller-identity --query Account --output text)

  [ -n "$SNAPSHOT" ] || SNAPSHOT=$(latest_final_snapshot)
  [ -n "$SNAPSHOT" ] && [ "$SNAPSHOT" != None ] || die "no final snapshot found - pass --snapshot ID"
  local snap_user; snap_user=$(aws rds describe-db-snapshots --db-snapshot-identifier "$SNAPSHOT" --query 'DBSnapshots[0].MasterUsername' --output text)

  say "Plan: recreate $STACK from snapshot $SNAPSHOT (expect 35-50 min)"
  local overrides=()
  while IFS='=' read -r k v; do overrides+=("$k=$v"); done < <(python3 -c "
import json,sys
p=json.load(open(sys.argv[1])); p.pop('DBSnapshotIdentifier',None); p['DBUsername']=sys.argv[2]
for k,v in sorted(p.items()):
    if v!='': print(f'{k}={v}')" "$PARAMS_FILE" "$snap_user")
  overrides+=("DBSnapshotIdentifier=$SNAPSHOT")
  printf '    %s\n' "${overrides[@]}" | sed 's/\(SSHLocationCidr=\).*/\1<saved>/'

  say "1/5 Template upload bucket (the stack's own bucket doesn't exist until it's created)"
  local bucket="$STACK-bootstrap-$account"
  if ! aws s3api head-bucket --bucket "$bucket" 2>/dev/null; then
    run aws s3api create-bucket --bucket "$bucket" --query Location --output text
    run aws s3api put-public-access-block --bucket "$bucket" --public-access-block-configuration BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
    run aws s3api put-bucket-lifecycle-configuration --bucket "$bucket" --lifecycle-configuration '{"Rules":[{"ID":"expire","Status":"Enabled","Filter":{},"Expiration":{"Days":7}}]}'
  fi
  echo "    $bucket"

  say "2/5 Creating the stack (runs in the background while step 3 watches for RDS)"
  local log="$STATE_DIR/up-$(date +%Y%m%d-%H%M%S).log" pid=""
  if $DRY_RUN; then
    echo "    [dry-run] aws cloudformation deploy --template-file $TEMPLATE --s3-bucket $bucket --stack-name $STACK --capabilities CAPABILITY_NAMED_IAM --parameter-overrides ..."
  else
    aws cloudformation deploy --template-file "$TEMPLATE" --s3-bucket "$bucket" --stack-name "$STACK" \
      --capabilities CAPABILITY_NAMED_IAM --parameter-overrides "${overrides[@]}" > "$log" 2>&1 &
    pid=$!
    echo "    log: $log"
  fi

  say "3/5 Setting the restored DB's password from the new secret as soon as RDS is up"
  echo "    (a snapshot keeps the old password; instances read the secret, so this must happen"
  echo "    before WordPress needs the DB - the read replica is created in between, which gives time)"
  if ! $DRY_RUN; then
    local db=""
    for _ in $(seq 180); do
      if [ "$(aws cloudformation describe-stack-resource --stack-name "$STACK" --logical-resource-id DBInstance --query StackResourceDetail.ResourceStatus --output text 2>/dev/null)" = CREATE_COMPLETE ]; then
        db=$(resource_id DBInstance); break
      fi
      kill -0 "$pid" 2>/dev/null || break
      sleep 20
    done
    [ -n "$db" ] || { wait "$pid" || true; tail -20 "$log"; die "RDS never reached CREATE_COMPLETE - see $log"; }
    aws rds wait db-instance-available --db-instance-identifier "$db"
    local pw; pw=$(aws secretsmanager get-secret-value --secret-id three-tier-app-db-master --query SecretString --output text \
                   | python3 -c 'import json,sys; print(json.load(sys.stdin)["password"])')
    # Retried: while CloudFormation creates the replica from it, RDS can briefly refuse modifications.
    local ok=false
    for _ in $(seq 20); do
      if aws rds modify-db-instance --db-instance-identifier "$db" --master-user-password "$pw" --apply-immediately \
           --query 'DBInstance.DBInstanceIdentifier' --output text >/dev/null 2>&1; then ok=true; break; fi
      sleep 30
    done
    unset pw
    $ok || { echo "    could not set the password - run 'Rotate the DB password' (Deployment.md) by hand"; }
    sleep 30; aws rds wait db-instance-available --db-instance-identifier "$db"
    echo "    $db: password set from three-tier-app-db-master"
  else
    echo "    [dry-run] wait for DBInstance CREATE_COMPLETE, then modify-db-instance --master-user-password <secret>"
  fi

  say "4/5 Waiting for the stack to finish"
  if ! $DRY_RUN; then
    wait "$pid" || { tail -20 "$log"; die "stack creation failed - see $log and the stack's events"; }
    echo "    $(stack_status "$STACK")"
  fi

  say "5/5 Verifying"
  $DRY_RUN && { echo "    [dry-run] would check: site returns 200, and (with --ssh-key) MySQL login to both endpoints"; return; }
  local url; url=$(output WordPressURL)
  local code=000
  for _ in $(seq 30); do code=$(curl -s -o /dev/null -w '%{http_code}' "$url/" || true); [ "$code" = 200 ] && break; sleep 20; done
  echo "    $url -> HTTP $code"
  local primary replica ip
  primary=$(output DBInstanceEndpoint); replica=$(output DBReadReplicaEndpoint)
  ip=$(aws ec2 describe-instances --filters Name=tag:Name,Values=three-tier-app-wordpress Name=instance-state-name,Values=running \
        --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)
  if [ -n "$SSH_KEY" ]; then
    # A page load isn't proof the DB works (Redis can serve pages with a dead DB) - log in for real.
    ssh -i "$SSH_KEY" -o StrictHostKeyChecking=accept-new "ec2-user@$ip" 'bash -s' "$primary" "$replica" <<'EOF'
export MYSQL_PWD=$(sudo php -r 'include "/etc/wordpress/db-secret.php"; echo DB_PASSWORD;')
U=$(sudo sed -n "s/.*'DB_USER', '\([^']*\)'.*/\1/p" /var/www/html/wp-config.php)
for h in "$@"; do echo "    ${h%%.*}: $(mysql -h "$h" -u "$U" -N -e "SELECT 'login OK', @@read_only" 2>&1 | tail -1)"; done
EOF
  else
    echo "    Not verified: the database login. Pass --ssh-key to check it, or run the diagnostic in"
    echo "    Deployment.md ('Site loads fine, but logins and writes fail') against $ip."
  fi
  echo "    Then log in to $url/wp-admin/ once - a login is the first thing that writes to the DB."
}

cmd=${1:-}; shift || true
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=true ;;
    --yes) YES=true ;;
    --snapshot) SNAPSHOT=$2; shift ;;
    --ssh-key) SSH_KEY=$2; shift ;;
    *) die "unknown option: $1" ;;
  esac
  shift
done
case "$cmd" in
  status) cmd_status ;;
  down) cmd_down ;;
  up) cmd_up ;;
  *) sed -n '2,20p' "$0"; exit 1 ;;
esac
