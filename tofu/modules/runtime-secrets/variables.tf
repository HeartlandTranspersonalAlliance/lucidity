variable "project_name" {
  description = "Project name used in runtime secret and IAM resource names."
  type        = string

  validation {
    condition     = can(regex("^[a-zA-Z0-9_-]+$", var.project_name))
    error_message = "The project name must contain only letters, numbers, underscores, and hyphens."
  }
}

variable "environment" {
  description = "Deployment environment used in runtime secret and IAM resource names."
  type        = string

  validation {
    condition     = can(regex("^[a-zA-Z0-9_-]+$", var.environment))
    error_message = "The environment must contain only letters, numbers, underscores, and hyphens."
  }
}

variable "recovery_window_in_days" {
  description = "Recovery window used if the runtime secret is scheduled for deletion."
  type        = number
  default     = 30

  validation {
    condition     = var.recovery_window_in_days >= 7 && var.recovery_window_in_days <= 30
    error_message = "The Secrets Manager recovery window must be between 7 and 30 days."
  }
}

variable "tags" {
  description = "Additional tags applied to supported resources."
  type        = map(string)
  default     = {}
}
