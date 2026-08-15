variable "project_name" {
  description = "Project prefix used for IAM resource names."
  type        = string
}

variable "environment" {
  description = "Environment name included in IAM resource names and tags."
  type        = string
}

variable "controller_policy_arns" {
  description = "Additional least-privilege policies attached only to the controller role."
  type        = set(string)
  default     = []
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
