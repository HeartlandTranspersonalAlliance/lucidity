variable "project_name" {
  description = "Project name used in EC2 launch template names and tags."
  type        = string
}

variable "environment" {
  description = "Environment tag applied to launch templates and launched resources."
  type        = string
}

variable "node_names" {
  description = "Stable Name tags for instances launched from each role template."
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

variable "controller_runtime_secret_name" {
  description = "Secrets Manager name embedded only as dynamic references in controller cloud-init user data."
  type        = string

  validation {
    condition     = can(regex("^[A-Za-z0-9/_+=.@-]{1,512}$", var.controller_runtime_secret_name))
    error_message = "The controller runtime secret name must be a valid Secrets Manager name."
  }
}

variable "deployment_contract" {
  description = "Non-secret deployment contract rendered as a root-only JSON file on both roles."
  type        = any

  validation {
    condition = (
      try(var.deployment_contract.schema_version, 0) == 1 &&
      contains(["production", "test"], try(var.deployment_contract.environment, "")) &&
      can(regex("^[a-z]{2}-[a-z]+-[0-9]+$", try(var.deployment_contract.region, ""))) &&
      can(regex("^v[0-9]+\\.[0-9]+\\.[0-9]+$", try(var.deployment_contract.release, ""))) &&
      can(regex("^[A-Za-z0-9/_+=.@-]{1,512}$", try(var.deployment_contract.runtime.controller_secret_id, ""))) &&
      can(regex("^alias/[A-Za-z0-9/_-]+$", try(var.deployment_contract.runtime.openbao_kms_alias, ""))) &&
      can(regex("^sha256:[0-9a-f]{64}$", try(var.deployment_contract.workloads.continuwuity.digest, "")))
    )
    error_message = "The deployment contract must be schema v1 with a supported environment, region, release, runtime identifiers, and pinned Continuwuity digest."
  }
}

variable "runtime_secret_names" {
  description = "Secrets Manager container names used only to build runtime dynamic references."
  type        = map(string)

  validation {
    condition = alltrue([
      for profile in ["controller_runtime", "monitoring", "restic_controller", "restic_worker"] :
      can(regex("^[A-Za-z0-9/_+=.@-]{1,512}$", var.runtime_secret_names[profile]))
    ])
    error_message = "Runtime secret names must include all controller, monitoring, and Restic profiles."
  }
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
