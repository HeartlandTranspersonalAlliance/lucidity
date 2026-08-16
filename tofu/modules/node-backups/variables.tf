variable "project_name" {
  description = "Project name applied to AWS Backup resources."
  type        = string
}

variable "environment" {
  description = "Environment applied to AWS Backup resources."
  type        = string
}

variable "instance_arns" {
  description = "Exact controller and worker EC2 instance ARNs protected by the backup plan."
  type        = map(string)

  validation {
    condition = (
      toset(keys(var.instance_arns)) == toset(["controller", "worker"]) &&
      alltrue([for arn in values(var.instance_arns) : can(regex(":ec2:[^:]+:[0-9]{12}:instance/i-[0-9a-f]+$", arn))])
    )
    error_message = "Node backups require exactly two EC2 instance ARNs."
  }
}

variable "instance_role_arns" {
  description = "Exact controller and worker runtime role ARNs that AWS Backup may pass back to EC2 during a restore."
  type        = map(string)

  validation {
    condition = (
      toset(keys(var.instance_role_arns)) == toset(["controller", "worker"]) &&
      alltrue([for arn in values(var.instance_role_arns) : can(regex(":iam::[0-9]{12}:role/", arn))])
    )
    error_message = "Node restore requires exactly two IAM role ARNs."
  }
}

variable "kms_key_arn" {
  description = "Customer-managed KMS key used by the backup vault and encrypted source volumes."
  type        = string

  validation {
    condition     = can(regex(":kms:[^:]+:[0-9]{12}:key/", var.kms_key_arn))
    error_message = "The backup vault KMS key must be a customer-managed KMS key ARN."
  }
}

variable "schedule" {
  description = "AWS Backup cron expression. AWS Backup evaluates this schedule in UTC."
  type        = string
  default     = "cron(0 5 ? * * *)"

  validation {
    condition     = can(regex("^cron\\(.+\\)$", var.schedule))
    error_message = "The backup schedule must be an AWS cron expression."
  }
}

variable "retention_days" {
  description = "Days each daily recovery point remains available."
  type        = number
  default     = 14

  validation {
    condition = (
      var.retention_days >= var.minimum_retention_days &&
      var.retention_days <= var.maximum_retention_days &&
      floor(var.retention_days) == var.retention_days
    )
    error_message = "Backup retention must be a whole number within the vault lock retention bounds."
  }
}

variable "minimum_retention_days" {
  description = "Governance-mode vault lock minimum retention."
  type        = number
  default     = 7

  validation {
    condition     = var.minimum_retention_days >= 1 && floor(var.minimum_retention_days) == var.minimum_retention_days
    error_message = "The vault minimum retention must be a positive whole number of days."
  }
}

variable "maximum_retention_days" {
  description = "Governance-mode vault lock maximum retention."
  type        = number
  default     = 365

  validation {
    condition = (
      var.maximum_retention_days >= var.minimum_retention_days &&
      var.maximum_retention_days <= 36500 &&
      floor(var.maximum_retention_days) == var.maximum_retention_days
    )
    error_message = "The vault maximum retention must be a whole number from its minimum through 36500 days."
  }
}

variable "start_window_minutes" {
  description = "Minutes after the scheduled time in which AWS Backup may start a job."
  type        = number
  default     = 60

  validation {
    condition     = var.start_window_minutes >= 60 && floor(var.start_window_minutes) == var.start_window_minutes
    error_message = "The AWS Backup start window must be a whole number of at least 60 minutes."
  }
}

variable "completion_window_minutes" {
  description = "Minutes after a job starts in which AWS Backup must complete it."
  type        = number
  default     = 240

  validation {
    condition     = var.completion_window_minutes >= 60 && floor(var.completion_window_minutes) == var.completion_window_minutes
    error_message = "The AWS Backup completion window must be a whole number of at least 60 minutes."
  }
}

variable "tags" {
  description = "Additional tags applied to supported backup resources."
  type        = map(string)
  default     = {}
}
