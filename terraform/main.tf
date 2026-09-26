# Three-tier web app. Creates a VPC in us-east-1 with one public subnet and
# one private subnet in a single Availability Zone, a MySQL RDS instance in
# the private subnet, and an EC2 instance in the public subnet that installs
# and configures WordPress to connect to that database. A second private
# subnet in another AZ is included solely because RDS requires a DB subnet
# group to span at least two Availability Zones; the database instance
# itself remains single-AZ.

data "aws_ssm_parameter" "amazon_linux_2" {
  name = "/aws/service/ami-amazon-linux-latest/amzn2-ami-hvm-x86_64-gp2"
}

resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "${var.environment_name}-vpc"
  }
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "${var.environment_name}-igw"
  }
}

resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.main.id
  availability_zone       = var.availability_zone
  cidr_block              = var.public_subnet_cidr
  map_public_ip_on_launch = true

  tags = {
    Name = "${var.environment_name}-public-subnet"
  }
}

resource "aws_subnet" "private" {
  vpc_id                  = aws_vpc.main.id
  availability_zone       = var.availability_zone
  cidr_block              = var.private_subnet_cidr
  map_public_ip_on_launch = false

  tags = {
    Name = "${var.environment_name}-private-subnet"
  }
}

resource "aws_subnet" "private_2" {
  vpc_id                  = aws_vpc.main.id
  availability_zone       = var.second_availability_zone
  cidr_block              = var.private_subnet_2_cidr
  map_public_ip_on_launch = false

  tags = {
    Name = "${var.environment_name}-private-subnet-2"
  }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "${var.environment_name}-public-rt"
  }
}

resource "aws_route" "public_internet_access" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.main.id
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "${var.environment_name}-private-rt"
  }
}

resource "aws_route_table_association" "private" {
  subnet_id      = aws_subnet.private.id
  route_table_id = aws_route_table.private.id
}

resource "aws_route_table_association" "private_2" {
  subnet_id      = aws_subnet.private_2.id
  route_table_id = aws_route_table.private.id
}

resource "aws_db_subnet_group" "main" {
  name        = "${var.environment_name}-db-subnet-group"
  description = "Subnet group for ${var.environment_name} RDS instance"
  subnet_ids  = [aws_subnet.private.id, aws_subnet.private_2.id]

  tags = {
    Name = "${var.environment_name}-db-subnet-group"
  }
}

resource "aws_security_group" "web_server" {
  name        = "${var.environment_name}-web-sg"
  description = "Allow HTTP and SSH access to the WordPress web server"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "HTTP access from anywhere"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "SSH access"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.ssh_location_cidr]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.environment_name}-web-sg"
  }
}

resource "aws_security_group" "db" {
  name        = "${var.environment_name}-db-sg"
  description = "Allow MySQL access from the web server only"
  vpc_id      = aws_vpc.main.id

  ingress {
    description     = "MySQL access from the WordPress web server"
    from_port       = 3306
    to_port         = 3306
    protocol        = "tcp"
    security_groups = [aws_security_group.web_server.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.environment_name}-db-sg"
  }
}

resource "aws_db_instance" "main" {
  identifier                = "${var.environment_name}-mysql"
  db_name                   = var.db_name
  engine                    = "mysql"
  engine_version            = var.db_engine_version
  instance_class            = var.db_instance_class
  allocated_storage         = var.db_allocated_storage
  username                  = var.db_username
  password                  = var.db_password
  db_subnet_group_name      = aws_db_subnet_group.main.name
  vpc_security_group_ids    = [aws_security_group.db.id]
  availability_zone         = var.availability_zone
  multi_az                  = false
  publicly_accessible       = false
  storage_type              = "gp3"
  backup_retention_period   = var.db_backup_retention_period
  deletion_protection       = false
  skip_final_snapshot       = false
  final_snapshot_identifier = "${var.environment_name}-mysql-final-snapshot"

  tags = {
    Name = "${var.environment_name}-mysql"
  }
}

resource "aws_instance" "wordpress" {
  ami                    = data.aws_ssm_parameter.amazon_linux_2.value
  instance_type          = var.web_server_instance_type
  key_name               = var.key_pair_name
  subnet_id              = aws_subnet.public.id
  vpc_security_group_ids = [aws_security_group.web_server.id]

  depends_on = [aws_db_instance.main]

  user_data = <<-EOF
    #!/bin/bash -xe
    yum update -y
    amazon-linux-extras enable php7.4
    yum clean metadata
    yum install -y httpd php php-mysqlnd php-fpm php-json php-gd php-xml php-mbstring mariadb wget

    systemctl start httpd
    systemctl enable httpd

    cd /tmp
    wget -q https://wordpress.org/latest.tar.gz
    tar -xzf latest.tar.gz

    cp -r wordpress/* /var/www/html/
    cd /var/www/html
    cp wp-config-sample.php wp-config.php

    sed -i "s/database_name_here/${var.db_name}/" wp-config.php
    sed -i "s/username_here/${var.db_username}/" wp-config.php
    sed -i "s/password_here/${var.db_password}/" wp-config.php
    sed -i "s/localhost/${aws_db_instance.main.address}/" wp-config.php

    chown -R apache:apache /var/www/html
    chmod -R 755 /var/www/html

    systemctl restart httpd
  EOF

  tags = {
    Name = "${var.environment_name}-wordpress"
  }
}
