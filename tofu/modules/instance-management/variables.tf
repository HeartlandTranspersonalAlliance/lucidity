variable "project_name" {
  description = "Project prefix used for IAM resource names."
  type        = string
}

variable "environment" {
  description = "Environment name included in IAM resource names and tags."
  type        = string
}

variable "controller_policies" {
  description = "Additional least-privilege policies attached only to the controller role, keyed by a stable purpose name."
  type        = map(string)
  default     = {}
}

variable "worker_policies" {
  description = "Additional least-privilege policies attached only to the worker role, keyed by a stable purpose name."
  type        = map(string)
  default     = {}
}

variable "application_backup_bucket_arn" {
  description = "Optional independent AWS S3 bucket ARN used by restic. The policy isolates each node to lucidity/<role>."
  type        = string
  default     = null
  nullable    = true

  validation {
    condition     = var.application_backup_bucket_arn == null || can(regex("^arn:[^:]+:s3:::[a-z0-9][a-z0-9.-]+$", var.application_backup_bucket_arn))
    error_message = "The application backup bucket must be a valid S3 bucket ARN or null."
  }
}

variable "application_backup_bucket_kms_key_arn" {
  description = "Optional KMS key ARN used by the independent AWS S3 backup bucket."
  type        = string
  default     = null
  nullable    = true
}

variable "application_backup_secret_arns" {
  description = "Exact SecretSpec-managed AWS Secrets Manager ARNs readable by each node for restic."
  type        = map(list(string))
  default = {
    controller = []
    worker     = []
  }

  validation {
    condition     = length(setsubtract(toset(keys(var.application_backup_secret_arns)), toset(["controller", "worker"]))) == 0
    error_message = "Application backup secret ARNs may be keyed only by controller and worker."
  }
}

variable "application_backup_secret_kms_key_arn" {
  description = "Optional KMS key ARN encrypting the SecretSpec-managed backup secrets."
  type        = string
  default     = null
  nullable    = true
}

variable "ecr_repository_arns" {
  description = "Private bootc ECR repository ARNs keyed by controller and worker role."
  type        = map(string)

  validation {
    condition = (
      length(var.ecr_repository_arns) == 2 &&
      alltrue([for role in ["controller", "worker"] : can(regex(":repository/", var.ecr_repository_arns[role]))])
    )
    error_message = "ECR repository ARNs must contain explicit controller and worker entries."
  }
}

variable "tags" {
  description = "Additional tags applied to supported IAM resources."
  type        = map(string)
  default     = {}
}
