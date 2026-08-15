variable "github_repository" {
  description = "GitHub repository in owner/name form."
  type        = string

  validation {
    condition     = can(regex("^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$", var.github_repository))
    error_message = "The GitHub repository must use owner/name form."
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
  description = "Only workflows on this branch may assume the publishing role."
  type        = string
  default     = "main"

  validation {
    condition     = length(trimspace(var.github_branch)) > 0
    error_message = "The trusted GitHub branch cannot be empty."
  }
}

variable "oidc_provider_arn" {
  description = "Existing GitHub Actions OIDC provider ARN. Null creates the account-level provider."
  type        = string
  default     = null
  nullable    = true

  validation {
    condition = (
      var.oidc_provider_arn == null ||
      can(regex("^arn:[^:]+:iam::[0-9]{12}:oidc-provider/token\\.actions\\.githubusercontent\\.com$", var.oidc_provider_arn))
    )
    error_message = "The OIDC provider ARN must identify token.actions.githubusercontent.com."
  }
}

variable "repository_arns" {
  description = "ECR repositories to which the GitHub role may publish."
  type        = set(string)

  validation {
    condition     = length(var.repository_arns) > 0
    error_message = "At least one ECR repository ARN is required."
  }
}

variable "role_name" {
  description = "Name of the IAM role assumed by GitHub Actions."
  type        = string
  default     = "lucidity-github-ecr-publisher"
}
