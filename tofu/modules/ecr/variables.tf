variable "repository_names" {
  description = "ECR repository names keyed by bootc image role."
  type        = map(string)

  validation {
    condition = (
      length(var.repository_names) > 0 &&
      alltrue([
        for name in values(var.repository_names) :
        can(regex("^[a-z0-9]+(?:[._/-][a-z0-9]+)*$", name))
      ])
    )
    error_message = "Each ECR repository name must use lowercase ECR-compatible characters."
  }
}

variable "expire_untagged_after_days" {
  description = "Days to retain untagged images before ECR expires them."
  type        = number
  default     = 7

  validation {
    condition     = var.expire_untagged_after_days >= 1
    error_message = "Untagged images must be retained for at least one day."
  }
}

variable "retain_tagged_images" {
  description = "Maximum number of tagged images retained in each repository."
  type        = number
  default     = 30

  validation {
    condition     = var.retain_tagged_images >= 2
    error_message = "At least two tagged images must be retained for bootc rollback."
  }
}
