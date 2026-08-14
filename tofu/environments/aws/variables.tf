variable "aws_region" {
  description = "AWS region in which the foundation resources are created."
  type        = string
  default     = "us-east-2"
}

variable "deployment_architecture" {
  description = "CPU architecture for the initial EC2 deployment. ARM64 remains a future option."
  type        = string
  default     = "amd64"

  validation {
    condition     = contains(["amd64", "arm64"], var.deployment_architecture)
    error_message = "The deployment architecture must be amd64 or arm64."
  }
}

variable "controller_instance_type" {
  description = "EC2 instance type reserved for the future controller launch template."
  type        = string
  default     = "t3a.small"
}

variable "worker_instance_type" {
  description = "EC2 instance type reserved for the future worker launch template."
  type        = string
  default     = "t3a.large"
}

variable "enable_network" {
  description = "Create the VPC and network controls needed by the future EC2 deployment."
  type        = bool
  default     = false
}

variable "enable_runtime_secrets" {
  description = "Create the controller runtime secret, KMS key, and instance profile when EC2 deployment begins."
  type        = bool
  default     = false
}

variable "vpc_name" {
  description = "Name prefix for production VPC resources."
  type        = string
  default     = "lucidity"
}

variable "environment" {
  description = "Environment tag applied to AWS resources."
  type        = string
  default     = "production"
}

variable "vpc_cidr" {
  description = "IPv4 CIDR block divided into public and private subnets."
  type        = string
  default     = "10.20.0.0/16"
}

variable "availability_zone_count" {
  description = "Number of available standard Availability Zones used by the VPC."
  type        = number
  default     = 3
}

variable "enable_nat_gateways" {
  description = "Create AZ-local NAT Gateways for private-subnet egress. Disabled for the lower-cost public-instance baseline."
  type        = bool
  default     = false
}

variable "allowed_web_cidrs" {
  description = "IPv4 CIDR blocks allowed to reach public HTTP and HTTPS listeners."
  type        = set(string)
  default     = ["0.0.0.0/0"]
}

variable "enable_ssh_access" {
  description = "Create a restricted administrator SSH security group."
  type        = bool
  default     = false
}

variable "ssh_allowed_cidrs" {
  description = "IPv4 CIDR blocks allowed to use the optional administrator SSH security group."
  type        = set(string)
  default     = ["10.0.0.0/8"]
}

variable "controller_bootstrap_cidrs" {
  description = "IPv4 CIDR blocks allowed to reach the controller bootstrap port 8000."
  type        = set(string)
  default     = []
}

variable "flow_log_retention_days" {
  description = "CloudWatch Logs retention for VPC Flow Logs."
  type        = number
  default     = 90
}

variable "secret_recovery_window_in_days" {
  description = "Recovery window used if the controller runtime secret is scheduled for deletion."
  type        = number
  default     = 30

  validation {
    condition     = var.secret_recovery_window_in_days >= 7 && var.secret_recovery_window_in_days <= 30
    error_message = "The Secrets Manager recovery window must be between 7 and 30 days."
  }
}

variable "github_repository" {
  description = "GitHub repository permitted to publish images."
  type        = string
  default     = "HeartlandTranspersonalAlliance/lucidity"
}

variable "github_publish_branch" {
  description = "Git branch permitted to publish images through OIDC."
  type        = string
  default     = "main"
}

variable "github_oidc_provider_arn" {
  description = "Existing account-level GitHub OIDC provider ARN, or null to create it."
  type        = string
  default     = null
  nullable    = true
}

variable "repository_prefix" {
  description = "Prefix for bootc ECR repository names."
  type        = string
  default     = "lucidity/bootc"

  validation {
    condition     = can(regex("^[a-z0-9]+(?:[._/-][a-z0-9]+)*$", var.repository_prefix))
    error_message = "The repository prefix must use lowercase ECR-compatible characters."
  }
}

variable "tags" {
  description = "Additional tags applied to supported AWS resources."
  type        = map(string)
  default     = {}
}
