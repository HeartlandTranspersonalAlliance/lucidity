variable "project_name" {
  description = "Project identifier included in the account budget name and tags."
  type        = string
}

variable "environment" {
  description = "Environment included in the account budget name and tags."
  type        = string
}

variable "annual_limit_usd" {
  description = "Annual account-wide AWS cost limit in US dollars."
  type        = number

  validation {
    condition     = var.annual_limit_usd >= 1 && var.annual_limit_usd <= 1000000
    error_message = "The annual account cost limit must be between 1 and 1,000,000 USD."
  }
}

variable "actual_warning_percentage" {
  description = "Actual-spend percentage that sends an early warning before the limit."
  type        = number
  default     = 80

  validation {
    condition     = var.actual_warning_percentage >= 1 && var.actual_warning_percentage < 100
    error_message = "The actual-spend warning must be at least 1 percent and below 100 percent."
  }
}

variable "notification_email" {
  description = "Email address receiving actual and forecasted account budget alerts."
  type        = string

  validation {
    condition     = can(regex("^[^@[:space:]]+@[^@[:space:]]+\\.[^@[:space:]]+$", var.notification_email))
    error_message = "The account budget notification endpoint must be a syntactically valid email address."
  }
}

variable "tags" {
  description = "Additional tags applied to the account budget."
  type        = map(string)
  default     = {}
}
