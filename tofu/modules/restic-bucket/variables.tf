variable "aws_region" {
  type        = string
  description = "AWS region containing the bucket."
}

variable "project_name" {
  type        = string
  description = "Project prefix for the bucket."
}

variable "environment" {
  type        = string
  description = "Isolated deployment environment."
}

variable "tags" {
  type        = map(string)
  description = "Additional resource tags."
  default     = {}
}
