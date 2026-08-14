variable "aws_region" {
  description = "AWS region used for the disposable AMI import validation."
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

variable "github_branch" {
  description = "GitHub branch allowed to assume the AMI validation role."
  type        = string
  default     = "main"
}

variable "oidc_provider_arn" {
  description = "GitHub Actions OIDC provider ARN."
  type        = string
}

variable "tags" {
  description = "Additional tags applied to supported resources."
  type        = map(string)
  default     = {}
}
