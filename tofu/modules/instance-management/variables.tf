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

variable "tags" {
  description = "Additional tags applied to supported IAM resources."
  type        = map(string)
  default     = {}
}
