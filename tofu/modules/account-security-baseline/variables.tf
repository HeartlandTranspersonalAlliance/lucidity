variable "project_name" {
  description = "Project name used in account security resource names."
  type        = string

  validation {
    condition     = can(regex("^[a-zA-Z0-9_-]+$", var.project_name))
    error_message = "The project name must contain only letters, numbers, underscores, and hyphens."
  }
}

variable "environment" {
  description = "Deployment environment used in account security resource names."
  type        = string

  validation {
    condition     = can(regex("^[a-zA-Z0-9_-]+$", var.environment))
    error_message = "The environment must contain only letters, numbers, underscores, and hyphens."
  }
}

variable "tags" {
  description = "Additional tags applied to supported resources."
  type        = map(string)
  default     = {}
}
