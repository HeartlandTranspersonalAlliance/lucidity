variable "aws_region" {
  description = "AWS region used for disposable AMI snapshot validation."
  type        = string
}

variable "project_name" {
  description = "Project name used in AMI import resource names."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]{1,31}$", var.project_name))
    error_message = "The project name must contain 2-32 lowercase letters, numbers, or hyphens."
  }
}

variable "environment" {
  description = "Environment tag applied to AMI import resources."
  type        = string
}

variable "github_repository" {
  description = "GitHub repository allowed to run the AMI import workflow."
  type        = string

  validation {
    condition     = can(regex("^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$", var.github_repository))
    error_message = "The GitHub repository must use owner/name syntax."
  }
}

variable "github_repository_owner_id" {
  description = "Immutable numeric ID of the GitHub repository owner."
  type        = string

  validation {
    condition     = can(regex("^[0-9]+$", var.github_repository_owner_id))
    error_message = "The GitHub repository owner ID must contain only digits."
  }
}

variable "github_repository_id" {
  description = "Immutable numeric ID of the GitHub repository."
  type        = string

  validation {
    condition     = can(regex("^[0-9]+$", var.github_repository_id))
    error_message = "The GitHub repository ID must contain only digits."
  }
}

variable "github_branch" {
  description = "GitHub branch allowed to assume the AMI validation role."
  type        = string
  default     = "main"
}

variable "oidc_provider_arn" {
  description = "GitHub Actions OIDC provider ARN."
  type        = string
}

variable "source_repository_arns" {
  description = "Private ECR repositories from which retained AMI source candidates may be pulled."
  type        = set(string)
  default     = []
}

variable "enable_launch_validation" {
  description = "Allow the GitHub AMI workflow to launch and terminate one tagged disposable EC2 validation instance."
  type        = bool
  default     = false
}

variable "launch_validation_subnet_ids" {
  description = "Public subnet IDs in which the disposable SSM validation instance may launch."
  type        = set(string)
  default     = []
}

variable "launch_validation_security_group_ids" {
  description = "Security group IDs that the disposable SSM validation instance may use."
  type        = set(string)
  default     = []
}

variable "launch_validation_instance_profile_names" {
  description = "Role-specific SSM-enabled instance profiles that may be attached to disposable validation instances."
  type        = set(string)
  default     = []
}

variable "launch_validation_role_arns" {
  description = "Role-specific EC2 role ARNs that GitHub may pass only to disposable validation instances."
  type        = set(string)
  default     = []
}

variable "launch_validation_instance_type" {
  description = "Single EC2 instance type permitted for disposable AMI boot validation."
  type        = string
  default     = "t3a.small"

  validation {
    condition     = var.launch_validation_instance_type == "t3a.small"
    error_message = "AMI launch validation is intentionally restricted to t3a.small."
  }
}

variable "tags" {
  description = "Additional tags applied to supported resources."
  type        = map(string)
  default     = {}
}
