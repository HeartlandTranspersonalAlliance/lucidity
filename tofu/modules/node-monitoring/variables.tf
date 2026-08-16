variable "aws_region" {
  description = "AWS region containing the monitored nodes and alarms."
  type        = string
}

variable "project_name" {
  description = "Project name applied to monitoring resources."
  type        = string
}

variable "environment" {
  description = "Environment applied to monitoring resources."
  type        = string
}

variable "instance_ids" {
  description = "Controller and worker EC2 instance IDs monitored by CloudWatch."
  type        = map(string)

  validation {
    condition = (
      toset(keys(var.instance_ids)) == toset(["controller", "worker"]) &&
      alltrue([for id in values(var.instance_ids) : can(regex("^i-[0-9a-f]+$", id))])
    )
    error_message = "Node monitoring requires controller and worker EC2 instance IDs."
  }
}

variable "notification_email" {
  description = "Email endpoint that must confirm the SNS alarm subscription after apply."
  type        = string

  validation {
    condition     = can(regex("^[^@[:space:]]+@[^@[:space:]]+\\.[^@[:space:]]+$", var.notification_email))
    error_message = "The alarm notification endpoint must be a syntactically valid email address."
  }
}

variable "high_cpu_threshold_percent" {
  description = "CPU utilization percentage that triggers the sustained high-CPU alarm."
  type        = number
  default     = 85

  validation {
    condition     = var.high_cpu_threshold_percent >= 50 && var.high_cpu_threshold_percent <= 100
    error_message = "The high-CPU threshold must be from 50 through 100 percent."
  }
}

variable "low_cpu_credit_threshold" {
  description = "T3a CPU credit balance that triggers the low-credit alarm."
  type        = number
  default     = 20

  validation {
    condition     = var.low_cpu_credit_threshold >= 0 && floor(var.low_cpu_credit_threshold) == var.low_cpu_credit_threshold
    error_message = "The low CPU credit threshold must be a non-negative whole number."
  }
}

variable "tags" {
  description = "Additional tags applied to monitoring resources."
  type        = map(string)
  default     = {}
}
