# Terraform

Terraform equivalent of [`../cloudformation/vpc.yaml`](../cloudformation/vpc.yaml). Deploys a VPC in `us-east-1` with one public subnet and one private subnet, a MySQL RDS instance in the private subnet, and an EC2 instance in the public subnet that installs and configures WordPress against that database.

A second private subnet in a different AZ is created solely because RDS requires a DB subnet group to span at least two Availability Zones — the RDS instance itself stays single-AZ.

Assumes Terraform >= 1.5 and AWS credentials configured (`aws configure` or an active SSO/profile session) with permission to create VPC, RDS, and EC2 resources.

## Required variables

`db_password` and `key_pair_name` have no defaults and must be supplied on every `plan`/`apply`.

- `db_password` — 8-41 characters, no `/`, `@`, `"`, or spaces.
- `key_pair_name` — name of an EC2 key pair that already exists in `us-east-1`.

### Create a key pair

Skip this if you already have one. Check first:

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

AWS only returns the private key material once — save the `.pem` file somewhere safe.

## Initialize

```bash
terraform init
```

## Plan

```bash
terraform plan \
  -var="db_password=<your-db-password>" \
  -var="key_pair_name=<your-key-pair-name>"
```

`ssh_location_cidr` defaults to `0.0.0.0/0` (open to the internet). Restrict it to your own IP for anything beyond a quick test:

```bash
terraform plan \
  -var="db_password=<your-db-password>" \
  -var="key_pair_name=<your-key-pair-name>" \
  -var="ssh_location_cidr=$(curl -s ifconfig.me)/32"
```

Other overridable variables (with defaults): `db_name` (`appdb`), `db_username` (`admin`), `db_instance_class` (`db.t3.micro`), `db_allocated_storage` (`20`), `db_backup_retention_period` (`1` — raise this only if your account is off the RDS free tier), `web_server_instance_type` (`t3.micro`).

## Apply

```bash
terraform apply \
  -var="db_password=<your-db-password>" \
  -var="key_pair_name=<your-key-pair-name>"
```

Since the EC2 instance's `user_data` references the RDS endpoint, Terraform waits for the database to finish creating before launching the web server — this can take 10-15 minutes.

To avoid retyping variables on every command, put them in a `terraform.tfvars` file instead (don't commit this file — it holds `db_password`):

```hcl
db_password    = "<your-db-password>"
key_pair_name  = "<your-key-pair-name>"
```

Then just run `terraform plan` / `terraform apply` with no `-var` flags.

## View outputs

```bash
terraform output
```

```bash
terraform output wordpress_url
```

## Access the WordPress site

Once `apply` finishes and the instance's `user_data` script completes (allow a few extra minutes after `apply` for WordPress to install), open the `wordpress_url` output in a browser to run the WordPress setup wizard. SSH access, if needed for troubleshooting:

```bash
ssh -i <your-key-pair-name>.pem ec2-user@$(terraform output -raw web_server_public_ip)
```

## Destroy

```bash
terraform destroy \
  -var="db_password=<your-db-password>" \
  -var="key_pair_name=<your-key-pair-name>"
```

The RDS instance is configured with `skip_final_snapshot = false`, so destroying takes a final snapshot instead of deleting the database outright.

## Note on running alongside the CloudFormation stack

This configuration provisions its own VPC, RDS instance, and EC2 instance independent of the CloudFormation stack in `../cloudformation/`. Running both at the same time creates two separate copies of the infrastructure (and doubles the cost) — they don't share state or resources. Use one or the other, or destroy one before standing up the other.
