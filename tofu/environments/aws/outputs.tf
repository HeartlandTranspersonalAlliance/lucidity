output "ecr_repository_arns" {
  description = "ECR repository ARNs keyed by bootc image role."
  value       = module.registry.repository_arns
}

output "ecr_repository_names" {
  description = "ECR repository names keyed by bootc image role."
  value       = module.registry.repository_names
}

output "ecr_repository_urls" {
  description = "ECR repository URLs keyed by bootc image role."
  value       = module.registry.repository_urls
}

output "github_oidc_provider_arn" {
  description = "GitHub Actions OIDC provider used by the publishing role."
  value       = module.github_oidc.oidc_provider_arn
}

output "github_oidc_subject" {
  description = "Exact GitHub OIDC subject permitted to publish images."
  value       = module.github_oidc.trusted_subject
}

output "github_publish_role_arn" {
  description = "IAM role ARN to configure in the GitHub publishing workflow."
  value       = module.github_oidc.publish_role_arn
}

output "deployment_architecture" {
  description = "CPU architecture selected for EC2 launch templates."
  value       = var.deployment_architecture
}

output "controller_instance_type" {
  description = "Controller EC2 instance type selected for the initial deployment."
  value       = var.controller_instance_type
}

output "worker_instance_type" {
  description = "Worker EC2 instance type selected for the initial deployment."
  value       = var.worker_instance_type
}

output "ec2_launch_template_ids" {
  description = "Hardened EC2 launch template IDs keyed by node role, or an empty map until explicitly enabled."
  value       = var.enable_ec2_launch_templates ? module.ec2_launch_templates[0].launch_template_ids : {}
}

output "ec2_launch_template_latest_versions" {
  description = "Latest numeric launch template versions keyed by node role for explicit deployment pinning."
  value       = var.enable_ec2_launch_templates ? module.ec2_launch_templates[0].launch_template_latest_versions : {}
}

output "selected_ami_ids" {
  description = "Self-owned AMI IDs explicitly selected for EC2 launch templates."
  value       = var.enable_ec2_launch_templates ? module.ec2_launch_templates[0].selected_ami_ids : {}
}

output "ec2_instance_ids" {
  description = "Production EC2 instance IDs keyed by node role, or an empty map until explicitly enabled."
  value       = var.enable_ec2_instances ? module.ec2_nodes[0].instance_ids : {}
}

output "ec2_private_ips" {
  description = "Production private VPC IPv4 addresses keyed by node role."
  value       = var.enable_ec2_instances ? module.ec2_nodes[0].private_ips : {}
}

output "ec2_public_ips" {
  description = "Production stable Elastic IPv4 addresses keyed by node role."
  value       = var.enable_ec2_instances ? module.ec2_nodes[0].public_ips : {}
}

output "ec2_elastic_ip_allocation_ids" {
  description = "Production Elastic IP allocation IDs keyed by node role."
  value       = var.enable_ec2_instances ? module.ec2_nodes[0].elastic_ip_allocation_ids : {}
}

output "ec2_availability_zones" {
  description = "Production Availability Zones keyed by node role."
  value       = var.enable_ec2_instances ? module.ec2_nodes[0].availability_zones : {}
}

output "ec2_instance_settings" {
  description = "Auditable production placement, protection, addressing, and pinned template settings keyed by node role."
  value       = var.enable_ec2_instances ? module.ec2_nodes[0].instance_settings : {}
}

output "vpc_id" {
  description = "Production VPC ID."
  value       = var.enable_network ? module.network[0].vpc_id : null
}

output "vpc_cidr" {
  description = "Production VPC CIDR block."
  value       = var.enable_network ? module.network[0].vpc_cidr : null
}

output "availability_zones" {
  description = "Availability Zones used by the production VPC."
  value       = var.enable_network ? module.network[0].availability_zones : []
}

output "public_subnet_ids" {
  description = "Public subnet IDs keyed by Availability Zone."
  value       = var.enable_network ? module.network[0].public_subnet_ids : {}
}

output "private_subnet_ids" {
  description = "Private subnet IDs keyed by Availability Zone."
  value       = var.enable_network ? module.network[0].private_subnet_ids : {}
}

output "nat_gateway_ids" {
  description = "NAT Gateway IDs keyed by Availability Zone."
  value       = var.enable_network ? module.network[0].nat_gateway_ids : {}
}

output "nat_gateway_public_ips" {
  description = "NAT Gateway public IPv4 addresses keyed by Availability Zone."
  value       = var.enable_network ? module.network[0].nat_gateway_public_ips : {}
}

output "internet_gateway_id" {
  description = "Internet Gateway attached to the production VPC."
  value       = var.enable_network ? module.network[0].internet_gateway_id : null
}

output "security_group_ids" {
  description = "Tiered security group IDs for controller, worker, database, and public web access."
  value       = var.enable_network ? module.network[0].security_group_ids : {}
}

output "vpc_flow_log_id" {
  description = "VPC Flow Log ID."
  value       = var.enable_network ? module.network[0].flow_log_id : null
}

output "vpc_flow_log_group_name" {
  description = "CloudWatch Logs group receiving VPC Flow Logs."
  value       = var.enable_network ? module.network[0].flow_log_group_name : null
}

output "controller_instance_profile_name" {
  description = "SSM-enabled instance profile for the controller."
  value       = var.enable_instance_management ? module.instance_management[0].instance_profile_names.controller : null
}

output "controller_runtime_role_arn" {
  description = "SSM-enabled IAM role ARN used by the controller EC2 instance."
  value       = var.enable_instance_management ? module.instance_management[0].role_arns.controller : null
}

output "worker_instance_profile_name" {
  description = "SSM-enabled instance profile for the worker."
  value       = var.enable_instance_management ? module.instance_management[0].instance_profile_names.worker : null
}

output "worker_runtime_role_arn" {
  description = "SSM-enabled IAM role ARN used by the worker EC2 instance."
  value       = var.enable_instance_management ? module.instance_management[0].role_arns.worker : null
}

output "controller_runtime_secret_arn" {
  description = "ARN of the controller runtime secret container."
  value       = var.enable_runtime_secrets ? module.runtime_secrets[0].secret_arn : null
}

output "controller_runtime_secret_name" {
  description = "Name of the controller runtime secret container."
  value       = var.enable_runtime_secrets ? module.runtime_secrets[0].secret_name : null
}

output "controller_runtime_secret_reference_pattern" {
  description = "asm-exec reference pattern for one JSON key in the controller runtime secret."
  value       = var.enable_runtime_secrets ? module.runtime_secrets[0].dynamic_reference_pattern : null
}

output "runtime_secrets_kms_key_arn" {
  description = "KMS key ARN encrypting the controller runtime secret."
  value       = var.enable_runtime_secrets ? module.runtime_secrets[0].kms_key_arn : null
}

output "ami_snapshot_kms_key_arn" {
  description = "Customer-managed KMS key ARN for encrypted AMI snapshot uploads."
  value       = module.ami_import_validation.snapshot_kms_key_arn
}

output "github_ami_validation_role_arn" {
  description = "GitHub Actions role ARN for manual AMI snapshot validation."
  value       = module.ami_import_validation.github_role_arn
}

output "github_ami_validation_subject" {
  description = "Exact GitHub OIDC subject allowed to run AMI snapshot validation."
  value       = module.ami_import_validation.github_subject
}

output "ami_launch_validation_enabled" {
  description = "Whether the main-branch AMI workflow may launch one tagged disposable t3a.small."
  value       = var.enable_ami_launch_validation
}

output "ami_test_subnet_id" {
  description = "Public subnet ID configured for the disposable SSM AMI boot test."
  value = var.enable_ami_launch_validation && var.enable_network ? module.network[0].public_subnet_ids[
    sort(keys(module.network[0].public_subnet_ids))[0]
  ] : null
}

output "ami_test_security_group_ids" {
  description = "Role-specific security group IDs used by disposable SSM AMI boot tests."
  value = var.enable_ami_launch_validation && var.enable_network ? {
    controller = module.network[0].security_group_ids.controller
    worker     = module.network[0].security_group_ids.application
  } : {}
}

output "ami_test_instance_profile_names" {
  description = "Role-specific SSM-enabled instance profiles used by disposable AMI boot tests."
  value       = var.enable_ami_launch_validation && var.enable_instance_management ? module.instance_management[0].instance_profile_names : {}
}

output "ami_test_instance_type" {
  description = "T3a instance type permitted for disposable AMI boot validation."
  value       = var.enable_ami_launch_validation ? var.controller_instance_type : null
}
