variable "project_name" {
  description = "Project name applied to EC2 node and Elastic IP tags."
  type        = string
}

variable "environment" {
  description = "Environment tag applied to EC2 nodes and Elastic IPs."
  type        = string
}

variable "node_names" {
  description = "Stable Name tags for the controller and worker nodes."
  type        = map(string)

  validation {
    condition = (
      length(var.node_names) == 2 &&
      alltrue([
        for role in ["controller", "worker"] :
        can(regex("^[A-Za-z0-9][A-Za-z0-9-]{1,62}$", var.node_names[role]))
      ])
    )
    error_message = "Node names must contain explicit controller and worker values using 2-63 letters, numbers, or hyphens."
  }
}

variable "subnet_ids" {
  description = "Public subnet IDs selected explicitly for each node role."
  type        = map(string)

  validation {
    condition = (
      length(var.subnet_ids) == 2 &&
      alltrue([
        for role in ["controller", "worker"] :
        can(regex("^subnet-[0-9a-f]+$", var.subnet_ids[role]))
      ])
    )
    error_message = "Subnet IDs must contain explicit controller and worker subnet-* values."
  }
}

variable "launch_template_ids" {
  description = "Hardened launch template IDs selected for each node role."
  type        = map(string)

  validation {
    condition = (
      length(var.launch_template_ids) == 2 &&
      alltrue([
        for role in ["controller", "worker"] :
        can(regex("^lt-[0-9a-f]+$", var.launch_template_ids[role]))
      ])
    )
    error_message = "Launch template IDs must contain explicit controller and worker lt-* values."
  }
}

variable "launch_template_versions" {
  description = "Numeric launch template versions pinned for each node role."
  type        = map(number)

  validation {
    condition = (
      length(var.launch_template_versions) == 2 &&
      alltrue([
        for role in ["controller", "worker"] :
        try(
          var.launch_template_versions[role] >= 1 &&
          floor(var.launch_template_versions[role]) == var.launch_template_versions[role],
          false,
        )
      ])
    )
    error_message = "Launch template versions must contain positive controller and worker integers."
  }
}

variable "enable_termination_protection" {
  description = "Protect production nodes from direct EC2 API termination."
  type        = bool
  default     = true
}

variable "tags" {
  description = "Additional tags applied to EC2 nodes and Elastic IPs."
  type        = map(string)
  default     = {}
}
