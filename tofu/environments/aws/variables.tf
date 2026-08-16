variable "aws_region" {
  description = "AWS region in which the foundation resources are created."
  type        = string
  default     = "us-east-2"
}

variable "deployment_architecture" {
  description = "CPU architecture for the initial EC2 deployment. ARM64 remains a future option."
  type        = string
  default     = "amd64"

  validation {
    condition     = contains(["amd64", "arm64"], var.deployment_architecture)
    error_message = "The deployment architecture must be amd64 or arm64."
  }
}

variable "controller_instance_type" {
  description = "EC2 instance type used by the controller launch template."
  type        = string
  default     = "t3a.small"
}

variable "worker_instance_type" {
  description = "EC2 instance type used by the worker launch template."
  type        = string
  default     = "t3a.large"
}

variable "enable_network" {
  description = "Create the VPC and network controls used by the EC2 deployment."
  type        = bool
  default     = false
}

variable "enable_runtime_secrets" {
  description = "Create the controller runtime secret, KMS key, and least-privilege IAM policy when EC2 deployment begins."
  type        = bool
  default     = false
}

variable "enable_instance_management" {
  description = "Create SSM-enabled controller and worker EC2 roles and instance profiles."
  type        = bool
  default     = false
}

variable "enable_ami_launch_validation" {
  description = "Temporarily grant the main-branch AMI workflow permission to boot and validate one tagged t3a.small through SSM. Requires networking and instance management."
  type        = bool
  default     = false
}

variable "enable_ec2_launch_templates" {
  description = "Create hardened controller and worker launch templates from explicitly selected retained AMI IDs."
  type        = bool
  default     = false

  validation {
    condition = !var.enable_ec2_launch_templates || (
      var.enable_network &&
      var.enable_instance_management &&
      var.enable_runtime_secrets &&
      var.deployment_architecture == "amd64" &&
      var.controller_ami_id != null &&
      var.worker_ami_id != null
    )
    error_message = "EC2 launch templates require the proven AMD64 architecture, explicit controller and worker AMI IDs, networking, instance management, and runtime secrets."
  }
}

variable "enable_ec2_instances" {
  description = "Launch the production controller and worker from pinned numeric launch template versions and associate stable Elastic IPs."
  type        = bool
  default     = false

  validation {
    condition     = !var.enable_ec2_instances || var.enable_ec2_launch_templates
    error_message = "EC2 instances require the hardened launch templates to be enabled."
  }
}

variable "ec2_node_names" {
  description = "Stable Name tags for the production controller and first worker."
  type        = map(string)
  default = {
    controller = "coolify-controller"
    worker     = "coolify-worker-01"
  }

  validation {
    condition = (
      length(var.ec2_node_names) == 2 &&
      alltrue([
        for role in ["controller", "worker"] :
        can(regex("^[A-Za-z0-9][A-Za-z0-9-]{1,62}$", var.ec2_node_names[role]))
      ])
    )
    error_message = "EC2 node names must contain explicit controller and worker values using 2-63 letters, numbers, or hyphens."
  }
}

variable "ec2_node_availability_zone_indices" {
  description = "Zero-based indices into the sorted selected Availability Zones for each production node. Both default to one AZ to avoid cross-AZ management traffic."
  type        = map(number)
  default = {
    controller = 0
    worker     = 0
  }

  validation {
    condition = (
      length(var.ec2_node_availability_zone_indices) == 2 &&
      alltrue([
        for role in ["controller", "worker"] :
        try(
          var.ec2_node_availability_zone_indices[role] >= 0 &&
          var.ec2_node_availability_zone_indices[role] < var.availability_zone_count &&
          floor(var.ec2_node_availability_zone_indices[role]) == var.ec2_node_availability_zone_indices[role],
          false,
        )
      ])
    )
    error_message = "Node Availability Zone indices must contain controller and worker integers within the selected Availability Zone count."
  }
}

variable "enable_ec2_termination_protection" {
  description = "Protect production controller and worker nodes from direct EC2 API termination."
  type        = bool
  default     = true
}

variable "controller_ami_id" {
  description = "Explicit retained controller AMI ID. No newest-image lookup or automatic rollout is performed."
  type        = string
  default     = null
  nullable    = true

  validation {
    condition     = var.controller_ami_id == null || can(regex("^ami-[0-9a-f]+$", var.controller_ami_id))
    error_message = "The controller AMI ID must be null or an ami-* identifier."
  }
}

variable "worker_ami_id" {
  description = "Explicit retained worker AMI ID. No newest-image lookup or automatic rollout is performed."
  type        = string
  default     = null
  nullable    = true

  validation {
    condition     = var.worker_ami_id == null || can(regex("^ami-[0-9a-f]+$", var.worker_ami_id))
    error_message = "The worker AMI ID must be null or an ami-* identifier."
  }
}

variable "controller_root_volume_size_gib" {
  description = "Encrypted gp3 root volume size for the controller launch template."
  type        = number
  default     = 40

  validation {
    condition     = var.controller_root_volume_size_gib >= 12
    error_message = "The controller root volume must be at least 12 GiB."
  }
}

variable "worker_root_volume_size_gib" {
  description = "Encrypted gp3 root volume size for the worker launch template."
  type        = number
  default     = 80

  validation {
    condition     = var.worker_root_volume_size_gib >= 12
    error_message = "The worker root volume must be at least 12 GiB."
  }
}

variable "vpc_name" {
  description = "Name prefix for production VPC resources."
  type        = string
  default     = "lucidity"
}

variable "environment" {
  description = "Environment tag applied to AWS resources."
  type        = string
  default     = "production"
}

variable "vpc_cidr" {
  description = "IPv4 CIDR block divided into public and private subnets."
  type        = string
  default     = "10.20.0.0/16"
}

variable "availability_zone_count" {
  description = "Number of available standard Availability Zones used by the VPC."
  type        = number
  default     = 3

  validation {
    condition     = var.availability_zone_count >= 2 && var.availability_zone_count <= 6
    error_message = "Use between two and six Availability Zones."
  }
}

variable "enable_nat_gateways" {
  description = "Create AZ-local NAT Gateways for private-subnet egress. Disabled for the lower-cost public-instance baseline."
  type        = bool
  default     = false
}

variable "allowed_web_cidrs" {
  description = "IPv4 CIDR blocks allowed to reach public HTTP and HTTPS listeners."
  type        = set(string)
  default     = ["0.0.0.0/0"]
}

variable "controller_outbound_tcp_ports" {
  description = "Internet TCP ports available to the controller security group."
  type        = set(number)
  default     = [443]
}

variable "application_outbound_tcp_ports" {
  description = "Internet TCP ports available to the worker security group."
  type        = set(number)
  default     = [443, 8448]
}

variable "flow_log_retention_days" {
  description = "CloudWatch Logs retention for VPC Flow Logs."
  type        = number
  default     = 90
}

variable "secret_recovery_window_in_days" {
  description = "Recovery window used if the controller runtime secret is scheduled for deletion."
  type        = number
  default     = 30

  validation {
    condition     = var.secret_recovery_window_in_days >= 7 && var.secret_recovery_window_in_days <= 30
    error_message = "The Secrets Manager recovery window must be between 7 and 30 days."
  }
}

variable "github_repository" {
  description = "GitHub repository permitted to publish images."
  type        = string
  default     = "HeartlandTranspersonalAlliance/lucidity"
}

variable "github_repository_owner_id" {
  description = "Immutable GitHub owner ID included in this repository's OIDC subject."
  type        = string
  default     = "256628390"

  validation {
    condition     = can(regex("^[0-9]+$", var.github_repository_owner_id))
    error_message = "The GitHub repository owner ID must contain only digits."
  }
}

variable "github_repository_id" {
  description = "Immutable GitHub repository ID included in this repository's OIDC subject."
  type        = string
  default     = "1333819830"

  validation {
    condition     = can(regex("^[0-9]+$", var.github_repository_id))
    error_message = "The GitHub repository ID must contain only digits."
  }
}

variable "github_publish_branch" {
  description = "Git branch permitted to publish images through OIDC."
  type        = string
  default     = "main"
}

variable "github_oidc_provider_arn" {
  description = "Existing account-level GitHub OIDC provider ARN, or null to create it."
  type        = string
  default     = null
  nullable    = true
}

variable "repository_prefix" {
  description = "Prefix for bootc ECR repository names."
  type        = string
  default     = "lucidity/bootc"

  validation {
    condition     = can(regex("^[a-z0-9]+(?:[._/-][a-z0-9]+)*$", var.repository_prefix))
    error_message = "The repository prefix must use lowercase ECR-compatible characters."
  }
}

variable "tags" {
  description = "Additional tags applied to supported AWS resources."
  type        = map(string)
  default     = {}
}
