output "vpc_id" {
  description = "Production VPC ID."
  value       = aws_vpc.this.id
}

output "vpc_cidr" {
  description = "Production VPC CIDR block."
  value       = aws_vpc.this.cidr_block
}

output "availability_zones" {
  description = "Availability Zones used by the VPC."
  value       = local.availability_zones
}

output "public_subnet_ids" {
  description = "Public subnet IDs keyed by Availability Zone."
  value       = { for zone, subnet in aws_subnet.public : zone => subnet.id }
}

output "private_subnet_ids" {
  description = "Private subnet IDs keyed by Availability Zone."
  value       = { for zone, subnet in aws_subnet.private : zone => subnet.id }
}

output "nat_gateway_ids" {
  description = "NAT Gateway IDs keyed by Availability Zone."
  value       = { for zone, gateway in aws_nat_gateway.this : zone => gateway.id }
}

output "nat_gateway_public_ips" {
  description = "NAT Gateway public IPv4 addresses keyed by Availability Zone."
  value       = { for zone, address in aws_eip.nat : zone => address.public_ip }
}

output "internet_gateway_id" {
  description = "Internet Gateway attached to the VPC."
  value       = aws_internet_gateway.this.id
}

output "security_group_ids" {
  description = "Tiered security group IDs."
  value = {
    application = aws_security_group.application.id
    controller  = aws_security_group.controller.id
    database    = aws_security_group.database.id
    web         = aws_security_group.web.id
  }
}

output "flow_log_id" {
  description = "VPC Flow Log ID."
  value       = aws_flow_log.rejected.id
}

output "flow_log_group_name" {
  description = "CloudWatch Logs group receiving VPC Flow Logs."
  value       = aws_cloudwatch_log_group.flow_logs.name
}

output "flow_log_settings" {
  description = "Cost and retention controls applied to VPC Flow Logs."
  value = {
    max_aggregation_interval_seconds = aws_flow_log.rejected.max_aggregation_interval
    retention_days                   = aws_cloudwatch_log_group.flow_logs.retention_in_days
    traffic_type                     = aws_flow_log.rejected.traffic_type
  }
}
