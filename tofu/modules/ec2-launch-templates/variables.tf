variable "project_name" {
  description = "Project name used in EC2 launch template names and tags."
  type        = string
}

variable "environment" {
  description = "Environment tag applied to launch templates and launched resources."
  type        = string
}

variable "ami_ids" {
  description = "Explicit retained AMI IDs for the controller and worker roles."
  type        = map(string)

  validation {
    condition = (
      length(var.ami_ids) == 2 &&
      alltrue([for role in ["controller", "worker"] : can(regex("^ami-[0-9a-f]+$", var.ami_ids[role]))])
    )
    error_message = "AMI IDs must contain explicit controller and worker ami-* values."
  }
}

variable "instance_types" {
  description = "EC2 instance types selected for each node role."
  type        = map(string)
}

variable "instance_profile_names" {
  description = "SSM-enabled instance profile names selected for each node role."
  type        = map(string)
}

variable "security_group_ids" {
  description = "Tiered VPC security group IDs used by the controller and worker templates."
  type        = map(string)
}

variable "root_volume_sizes" {
  description = "Root gp3 volume size in GiB for each node role."
  type        = map(number)

  validation {
    condition = (
      var.root_volume_sizes.controller >= 12 &&
      var.root_volume_sizes.worker >= 12
    )
    error_message = "Each root volume must be at least as large as the 12 GiB AMI artifact."
  }
}

variable "root_volume_kms_key_arn" {
  description = "Customer-managed KMS key used to encrypt EC2 root volumes."
  type        = string
}

variable "tags" {
  description = "Additional tags applied to launch templates and launched resources."
  type        = map(string)
  default     = {}
}
