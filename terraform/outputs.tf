output "vpc_id" {
  description = "VPC ID"
  value       = aws_vpc.main.id
}

output "public_subnet_id" {
  description = "Public subnet ID"
  value       = aws_subnet.public.id
}

output "private_subnet_id" {
  description = "Private subnet ID"
  value       = aws_subnet.private.id
}

output "private_subnet_2_id" {
  description = "Second private subnet ID (DB subnet group only)"
  value       = aws_subnet.private_2.id
}

output "public_route_table_id" {
  description = "Public route table ID"
  value       = aws_route_table.public.id
}

output "private_route_table_id" {
  description = "Private route table ID"
  value       = aws_route_table.private.id
}

output "db_subnet_group_name" {
  description = "RDS DB subnet group name"
  value       = aws_db_subnet_group.main.name
}

output "db_security_group_id" {
  description = "Security group ID for the RDS instance"
  value       = aws_security_group.db.id
}

output "db_instance_endpoint" {
  description = "RDS instance connection endpoint"
  value       = aws_db_instance.main.address
}

output "db_instance_port" {
  description = "RDS instance connection port"
  value       = aws_db_instance.main.port
}

output "web_server_security_group_id" {
  description = "Security group ID for the WordPress web server"
  value       = aws_security_group.web_server.id
}

output "web_server_public_ip" {
  description = "Public IP address of the WordPress web server"
  value       = aws_instance.wordpress.public_ip
}

output "web_server_public_dns_name" {
  description = "Public DNS name of the WordPress web server"
  value       = aws_instance.wordpress.public_dns
}

output "wordpress_url" {
  description = "URL to access the WordPress site"
  value       = "http://${aws_instance.wordpress.public_dns}"
}
