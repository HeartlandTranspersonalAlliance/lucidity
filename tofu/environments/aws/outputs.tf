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
  description = "CPU architecture selected for future EC2 launch templates."
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
  description = "Tiered security group IDs for controller, worker, database, web, and optional SSH access."
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
  description = "Instance profile granting the future controller access to its runtime secret."
  value       = var.enable_runtime_secrets ? module.runtime_secrets[0].controller_instance_profile_name : null
}

output "controller_runtime_role_arn" {
  description = "IAM role ARN used by the future controller EC2 instance."
  value       = var.enable_runtime_secrets ? module.runtime_secrets[0].controller_role_arn : null
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

output "ami_import_bucket_name" {
  description = "Private S3 bucket used by disposable GitHub AMI import validation."
  value       = module.ami_import_validation.bucket_name
}

output "github_ami_validation_role_arn" {
  description = "GitHub Actions role ARN for manual AMI import validation."
  value       = module.ami_import_validation.github_role_arn
}

output "github_ami_validation_subject" {
  description = "Exact GitHub OIDC subject allowed to run AMI import validation."
  value       = module.ami_import_validation.github_subject
}

output "vmimport_role_name" {
  description = "VM Import Export service role used for disposable AMI validation."
  value       = module.ami_import_validation.vmimport_role_name
}
