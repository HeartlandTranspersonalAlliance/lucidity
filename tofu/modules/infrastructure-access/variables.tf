variable "aws_region" {
  description = "AWS region containing the isolated deployment."
  type        = string
}

variable "environment" {
  description = "Deployment environment isolated by the roles."
  type        = string
}

variable "project_name" {
  description = "Project prefix and mandatory Project tag value."
  type        = string
}

variable "github_repository" {
  description = "GitHub repository in owner/name form."
  type        = string
}

variable "github_repository_owner_id" {
  description = "Immutable numeric GitHub owner ID."
  type        = string
}

variable "github_repository_id" {
  description = "Immutable numeric GitHub repository ID."
  type        = string
}

variable "github_branch" {
  description = "Branch allowed to produce plans."
  type        = string
  default     = "main"
}

variable "github_environment" {
  description = "Protected GitHub environment allowed to apply."
  type        = string
}

variable "oidc_provider_arn" {
  description = "Existing account-level GitHub OIDC provider ARN."
  type        = string
}

variable "state_bucket_name" {
  description = "Dedicated state bucket created by the isolated state bootstrap."
  type        = string
}

variable "state_key" {
  description = "Exact OpenTofu state object key."
  type        = string
}

variable "tags" {
  description = "Additional tags applied to the roles."
  type        = map(string)
  default     = {}
}
