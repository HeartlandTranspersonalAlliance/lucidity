variable "aws_region" {
  description = "AWS region containing the production nodes."
  type        = string
}

variable "project_name" {
  description = "Project tag required on every node targeted through SSM."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]{1,31}$", var.project_name))
    error_message = "The project name must contain 2-32 lowercase letters, numbers, or hyphens."
  }
}

variable "environment" {
  description = "Environment tag required on every node targeted through SSM."
  type        = string
}

variable "github_repository" {
  description = "GitHub repository allowed to run production deployment validation."
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
  description = "GitHub branch allowed to assume the deployment-validation role."
  type        = string
  default     = "main"
}

variable "oidc_provider_arn" {
  description = "GitHub Actions OIDC provider ARN."
  type        = string
}

variable "tags" {
  description = "Additional tags applied to the deployment-validation IAM role."
  type        = map(string)
  default     = {}
}
