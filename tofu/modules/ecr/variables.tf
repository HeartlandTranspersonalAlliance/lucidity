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

variable "mutable_channel_tags" {
  description = "Exact bootc channel tags permitted to move to a newly tested immutable image."
  type        = set(string)
  default     = ["stable"]

  validation {
    condition = (
      length(var.mutable_channel_tags) <= 5 &&
      alltrue([
        for tag in var.mutable_channel_tags :
        can(regex("^[A-Za-z0-9_][A-Za-z0-9._-]{0,127}$", tag))
      ])
    )
    error_message = "Use at most five exact ECR-compatible mutable channel tags."
  }
}
