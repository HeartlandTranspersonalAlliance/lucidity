variable "aws_region" {
  description = "AWS region for the account-regional OpenTofu state and access-log buckets."
  type        = string
  default     = "us-east-2"
}

variable "project_name" {
  description = "Project name used in state bucket names and tags."
  type        = string
  default     = "lucidity"

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]{1,19}$", var.project_name))
    error_message = "The project name must contain 2-20 lowercase letters, numbers, or hyphens."
  }
}

variable "environment" {
  description = "Environment name used in state bucket names, object keys, and tags."
  type        = string
  default     = "production"

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]{1,19}$", var.environment))
    error_message = "The environment must contain 2-20 lowercase letters, numbers, or hyphens."
  }
}

variable "access_log_retention_days" {
  description = "Days to retain state-bucket S3 server access logs."
  type        = number
  default     = 365

  validation {
    condition     = var.access_log_retention_days >= 90
    error_message = "Retain state access logs for at least 90 days."
  }
}

variable "tags" {
  description = "Additional tags applied to state bootstrap resources."
  type        = map(string)
  default     = {}
}
