variable "vpc_name" {
  description = "Name prefix for VPC resources."
  type        = string

  validation {
    condition     = can(regex("^[A-Za-z0-9][A-Za-z0-9-]{1,31}$", var.vpc_name))
    error_message = "The VPC name must contain 2-32 letters, numbers, or hyphens."
  }
}

variable "environment" {
  description = "Environment tag applied to network resources."
  type        = string

  validation {
    condition     = length(trimspace(var.environment)) > 0
    error_message = "The environment cannot be empty."
  }
}

variable "vpc_cidr" {
  description = "IPv4 CIDR block divided into public and private subnets."
  type        = string
  default     = "10.20.0.0/16"

  validation {
    condition     = can(cidrhost(var.vpc_cidr, 0))
    error_message = "The VPC CIDR must be a valid IPv4 CIDR block."
  }
}

variable "availability_zone_count" {
  description = "Number of available standard Availability Zones to use."
  type        = number
  default     = 3

  validation {
    condition     = var.availability_zone_count >= 2 && var.availability_zone_count <= 6
    error_message = "Use between two and six Availability Zones."
  }
}

variable "enable_nat_gateways" {
  description = "Create one NAT Gateway per selected Availability Zone for private-subnet egress."
  type        = bool
  default     = false
}

variable "allowed_web_cidrs" {
  description = "IPv4 CIDR blocks allowed to reach public HTTP and HTTPS listeners."
  type        = set(string)
  default     = ["0.0.0.0/0"]

  validation {
    condition = alltrue([
      for cidr in var.allowed_web_cidrs : can(cidrhost(cidr, 0))
    ])
    error_message = "Every web ingress entry must be a valid IPv4 CIDR block."
  }
}

variable "enable_ssh_access" {
  description = "Create an administrator SSH security group."
  type        = bool
  default     = false
}

variable "ssh_allowed_cidrs" {
  description = "IPv4 CIDR blocks allowed to use the optional administrator SSH security group."
  type        = set(string)
  default     = ["10.0.0.0/8"]

  validation {
    condition = alltrue([
      for cidr in var.ssh_allowed_cidrs : can(cidrhost(cidr, 0))
    ])
    error_message = "Every SSH ingress entry must be a valid IPv4 CIDR block."
  }
}

variable "controller_bootstrap_cidrs" {
  description = "IPv4 CIDR blocks allowed to reach the controller bootstrap port 8000."
  type        = set(string)
  default     = []

  validation {
    condition = alltrue([
      for cidr in var.controller_bootstrap_cidrs : can(cidrhost(cidr, 0))
    ])
    error_message = "Every controller bootstrap entry must be a valid IPv4 CIDR block."
  }
}

variable "flow_log_retention_days" {
  description = "CloudWatch Logs retention for VPC Flow Logs."
  type        = number
  default     = 90

  validation {
    condition = contains([
      1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545,
      731, 1096, 1827, 2192, 2557, 2922, 3288, 3653,
    ], var.flow_log_retention_days)
    error_message = "Flow-log retention must be a CloudWatch Logs supported retention period."
  }
}

variable "tags" {
  description = "Additional tags applied to network resources."
  type        = map(string)
  default     = {}
}
