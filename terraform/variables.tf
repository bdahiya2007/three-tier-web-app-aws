variable "environment_name" {
  type        = string
  default     = "three-tier-app"
  description = "Name prefix used to tag resources."
}

variable "availability_zone" {
  type        = string
  default     = "us-east-1a"
  description = "Availability Zone for the public subnet, primary private subnet, and RDS instance."
}

variable "second_availability_zone" {
  type        = string
  default     = "us-east-1b"
  description = "Second Availability Zone, required only to satisfy the RDS DB subnet group's multi-AZ subnet requirement."
}

variable "vpc_cidr" {
  type        = string
  default     = "10.0.0.0/16"
  description = "CIDR block for the VPC."
}

variable "public_subnet_cidr" {
  type        = string
  default     = "10.0.1.0/24"
  description = "CIDR block for the public subnet."
}

variable "private_subnet_cidr" {
  type        = string
  default     = "10.0.2.0/24"
  description = "CIDR block for the private subnet."
}

variable "private_subnet_2_cidr" {
  type        = string
  default     = "10.0.3.0/24"
  description = "CIDR block for the second private subnet (DB subnet group only)."
}

variable "db_name" {
  type        = string
  default     = "appdb"
  description = "Initial database name created on the RDS instance."
}

variable "db_username" {
  type        = string
  default     = "admin"
  description = "Master username for the RDS instance."
  sensitive   = true
}

variable "db_password" {
  type        = string
  description = "Master password for the RDS instance (8-41 characters, no '/', '@', '\"', or spaces)."
  sensitive   = true

  validation {
    condition     = length(var.db_password) >= 8 && length(var.db_password) <= 41 && !can(regex("[/@\"[:space:]]", var.db_password))
    error_message = "DB password must be 8-41 characters and must not contain '/', '@', '\"', or spaces."
  }
}

variable "db_instance_class" {
  type        = string
  default     = "db.t3.micro"
  description = "RDS instance class."
}

variable "db_allocated_storage" {
  type        = number
  default     = 20
  description = "Allocated storage for the RDS instance, in GiB."
}

variable "db_engine_version" {
  type        = string
  default     = "8.0"
  description = "MySQL engine version."
}

variable "db_backup_retention_period" {
  type        = number
  default     = 1
  description = "Automated backup retention period in days (free-tier accounts are capped at 1)."
}

variable "key_pair_name" {
  type        = string
  description = "Name of an existing EC2 key pair (in this region) for SSH access to the web server."
}

variable "web_server_instance_type" {
  type        = string
  default     = "t3.micro"
  description = "EC2 instance type for the WordPress web server."
}

variable "ssh_location_cidr" {
  type        = string
  default     = "0.0.0.0/0"
  description = "CIDR block allowed to SSH into the web server. Restrict this to your own IP (e.g. 203.0.113.5/32) instead of leaving it open to the internet."

  validation {
    condition     = can(regex("^(\\d{1,3}\\.){3}\\d{1,3}/\\d{1,2}$", var.ssh_location_cidr))
    error_message = "ssh_location_cidr must be a valid CIDR block, e.g. 203.0.113.5/32."
  }
}
