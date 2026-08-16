mock_provider "aws" {
  mock_resource "aws_cloudwatch_log_group" {
    defaults = {
      arn = "arn:aws:logs:us-east-2:123456789012:log-group:/vpc/lucidity/flow-logs"
    }
  }

  mock_resource "aws_iam_role" {
    defaults = {
      arn = "arn:aws:iam::123456789012:role/lucidity-mock-role"
    }
  }

  mock_resource "aws_iam_instance_profile" {
    defaults = {
      arn = "arn:aws:iam::123456789012:instance-profile/lucidity-production-controller-profile"
    }
  }

  mock_resource "aws_iam_policy" {
    defaults = {
      arn = "arn:aws:iam::123456789012:policy/lucidity-production-controller-secrets"
    }
  }

  mock_resource "aws_ecr_repository" {
    defaults = {
      arn = "arn:aws:ecr:us-east-2:123456789012:repository/lucidity/bootc/mock"
    }
  }

  mock_resource "aws_eip" {
    defaults = {
      id        = "eipalloc-0123456789abcdef0"
      public_ip = "198.51.100.10"
    }
  }

  mock_resource "aws_instance" {
    defaults = {
      availability_zone = "us-east-2a"
      id                = "i-0123456789abcdef0"
      private_ip        = "10.20.0.10"
    }
  }

  mock_resource "aws_kms_key" {
    defaults = {
      arn    = "arn:aws:kms:us-east-2:123456789012:key/11111111-2222-3333-4444-555555555555"
      key_id = "11111111-2222-3333-4444-555555555555"
    }
  }

  mock_resource "aws_secretsmanager_secret" {
    defaults = {
      arn = "arn:aws:secretsmanager:us-east-2:123456789012:secret:lucidity/production/controller-runtime-AbCdEf"
    }
  }

  mock_resource "aws_s3_bucket" {
    defaults = {
      arn = "arn:aws:s3:::lucidity-ami-import-123456789012-us-east-2"
    }
  }

  mock_resource "aws_subnet" {
    defaults = {
      id = "subnet-0123456789abcdef0"
    }
  }

  mock_resource "aws_launch_template" {
    defaults = {
      id             = "lt-0123456789abcdef0"
      latest_version = 1
    }
  }

  mock_resource "aws_security_group" {
    defaults = {
      id = "sg-0123456789abcdef0"
    }
  }

  mock_data "aws_availability_zones" {
    defaults = {
      names    = ["us-east-2a", "us-east-2b", "us-east-2c"]
      zone_ids = ["use2-az1", "use2-az2", "use2-az3"]
    }
  }

  mock_data "aws_caller_identity" {
    defaults = {
      account_id = "123456789012"
      arn        = "arn:aws:iam::123456789012:user/mock"
      user_id    = "AIDAMOCK"
    }
  }

  mock_data "aws_partition" {
    defaults = {
      dns_suffix = "amazonaws.com"
      partition  = "aws"
    }
  }

  mock_data "aws_iam_policy_document" {
    defaults = {
      json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
    }
  }

  mock_data "aws_ami" {
    defaults = {
      architecture        = "x86_64"
      boot_mode           = "uefi"
      ena_support         = true
      image_id            = "ami-0123456789abcdef0"
      imds_support        = "v2.0"
      owner_id            = "123456789012"
      root_device_type    = "ebs"
      state               = "available"
      virtualization_type = "hvm"
    }
  }
}

run "default_registry_and_oidc_contract" {
  command = plan

  assert {
    condition = output.ecr_repository_names == {
      controller = "lucidity/bootc/controller"
      worker     = "lucidity/bootc/worker"
    }
    error_message = "The default controller and worker repository names changed unexpectedly."
  }

  assert {
    condition     = output.github_oidc_subject == "repo:HeartlandTranspersonalAlliance@256628390/lucidity@1333819830:ref:refs/heads/main"
    error_message = "The GitHub OIDC trust must remain restricted to this immutable repository identity and main branch."
  }

  assert {
    condition     = output.deployment_architecture == "amd64"
    error_message = "The initial AWS deployment must default to AMD64."
  }

  assert {
    condition = (
      output.controller_instance_type == "t3a.small" &&
      output.worker_instance_type == "t3a.large"
    )
    error_message = "The initial controller and worker must retain the selected T3a defaults."
  }

  assert {
    condition = (
      length(output.ec2_launch_template_ids) == 0 &&
      length(output.selected_ami_ids) == 0 &&
      length(output.ec2_instance_ids) == 0 &&
      length(output.ec2_public_ips) == 0
    )
    error_message = "Launch templates and production nodes must remain absent until retained AMI IDs and deployment are explicitly selected."
  }

  assert {
    condition = (
      length(output.public_subnet_ids) == 0 &&
      length(output.private_subnet_ids) == 0 &&
      length(output.nat_gateway_ids) == 0
    )
    error_message = "The initial image-pipeline bootstrap must not create networking before EC2 deployment."
  }

  assert {
    condition     = output.controller_runtime_secret_name == null
    error_message = "The initial image-pipeline bootstrap must not create billed runtime secrets before controller deployment."
  }


  assert {
    condition = (
      output.controller_instance_profile_name == null &&
      output.worker_instance_profile_name == null
    )
    error_message = "The initial image-pipeline bootstrap must not create EC2 instance profiles."
  }


  assert {
    condition     = output.ami_snapshot_kms_key_arn == "arn:aws:kms:us-east-2:123456789012:key/11111111-2222-3333-4444-555555555555"
    error_message = "AMI validation must expose its customer-managed EBS snapshot encryption key."
  }

  assert {
    condition     = output.github_ami_validation_subject == "repo:HeartlandTranspersonalAlliance@256628390/lucidity@1333819830:ref:refs/heads/main"
    error_message = "AMI import credentials must remain restricted to this immutable repository identity and main branch."
  }

  assert {
    condition = (
      output.ami_launch_validation_enabled == false &&
      output.ami_test_subnet_id == null &&
      length(output.ami_test_security_group_ids) == 0 &&
      length(output.ami_test_instance_profile_names) == 0
    )
    error_message = "Disposable EC2 launch permissions and identifiers must remain disabled during the initial image-pipeline bootstrap."
  }
}

run "ec2_foundation_contract" {
  command = plan

  variables {
    enable_instance_management = true
    enable_network             = true
    enable_runtime_secrets     = true
  }

  assert {
    condition = (
      length(output.public_subnet_ids) == 3 &&
      length(output.private_subnet_ids) == 3 &&
      length(output.nat_gateway_ids) == 0
    )
    error_message = "The lower-cost EC2 VPC must retain three public and private subnets while leaving NAT disabled by default."
  }

  assert {
    condition     = length(output.security_group_ids) == 4
    error_message = "The default EC2 network must create web, controller, application, and database security groups without public SSH."
  }

  assert {
    condition     = output.controller_runtime_secret_name == "lucidity/production/controller-runtime"
    error_message = "The controller runtime secret must use the expected project and environment path."
  }

  assert {
    condition     = output.controller_instance_profile_name == "lucidity-production-controller-profile"
    error_message = "The future controller must receive the SSM-enabled instance profile."
  }

  assert {
    condition     = output.worker_instance_profile_name == "lucidity-production-worker-profile"
    error_message = "The future worker must receive the SSM-enabled instance profile."
  }

  assert {
    condition     = output.controller_runtime_secret_reference_pattern == "{{resolve:secretsmanager:lucidity/production/controller-runtime:SecretString:json-key}}"
    error_message = "Runtime secret references must use the asm-exec-compatible dynamic reference pattern."
  }
}

run "existing_oidc_provider" {
  command = plan

  variables {
    github_oidc_provider_arn = "arn:aws:iam::123456789012:oidc-provider/token.actions.githubusercontent.com"
  }

  assert {
    condition     = output.github_oidc_provider_arn == "arn:aws:iam::123456789012:oidc-provider/token.actions.githubusercontent.com"
    error_message = "An existing account-level GitHub OIDC provider must be reusable."
  }
}

run "explicit_ami_launch_template_contract" {
  command = plan

  variables {
    controller_ami_id           = "ami-01111111111111111"
    enable_ec2_launch_templates = true
    enable_instance_management  = true
    enable_network              = true
    enable_runtime_secrets      = true
    worker_ami_id               = "ami-02222222222222222"
  }

  assert {
    condition = (
      length(output.ec2_launch_template_ids) == 2 &&
      output.ec2_launch_template_latest_versions.controller == 1 &&
      output.ec2_launch_template_latest_versions.worker == 1
    )
    error_message = "Explicit retained AMIs must create one numerically versioned launch template per node role."
  }
}

run "production_ec2_nodes_contract" {
  command = plan

  variables {
    controller_ami_id           = "ami-01111111111111111"
    enable_ec2_instances        = true
    enable_ec2_launch_templates = true
    enable_instance_management  = true
    enable_network              = true
    enable_runtime_secrets      = true
    worker_ami_id               = "ami-02222222222222222"
  }

  assert {
    condition = (
      output.ec2_instance_ids.controller == "i-0123456789abcdef0" &&
      output.ec2_instance_ids.worker == "i-0123456789abcdef0" &&
      output.ec2_private_ips.controller == "10.20.0.10" &&
      output.ec2_public_ips.worker == "198.51.100.10" &&
      output.ec2_elastic_ip_allocation_ids.controller == "eipalloc-0123456789abcdef0" &&
      output.ec2_availability_zones.worker == "us-east-2a"
    )
    error_message = "The production deployment must create one pinned controller and worker with stable private and public addressing."
  }

  assert {
    condition = (
      output.ec2_instance_settings.controller.associate_public_ip_address == false &&
      output.ec2_instance_settings.controller.disable_api_termination == true &&
      output.ec2_instance_settings.controller.instance_initiated_shutdown_action == "stop" &&
      output.ec2_instance_settings.controller.launch_template_version == "1" &&
      output.ec2_instance_settings.controller.subnet_id == "subnet-0123456789abcdef0"
    )
    error_message = "Production nodes must suppress ephemeral public IPs, protect termination, stop on guest shutdown, and pin a numeric launch template version."
  }
}

run "ami_launch_validation_contract" {
  command = plan

  variables {
    enable_ami_launch_validation = true
    enable_instance_management   = true
    enable_network               = true
  }

  assert {
    condition = (
      output.ami_launch_validation_enabled == true &&
      output.ami_test_instance_type == "t3a.small" &&
      output.ami_test_instance_profile_names.controller == "lucidity-production-controller-profile" &&
      output.ami_test_instance_profile_names.worker == "lucidity-production-worker-profile" &&
      output.ami_test_subnet_id == "subnet-0123456789abcdef0" &&
      output.ami_test_security_group_ids.controller == "sg-0123456789abcdef0" &&
      output.ami_test_security_group_ids.worker == "sg-0123456789abcdef0"
    )
    error_message = "The disposable AMI launch gate must expose only the selected t3a.small, public subnet, and role-specific security groups and SSM profiles."
  }
}

run "two_az_network_and_restricted_egress" {
  command = plan

  variables {
    application_outbound_tcp_ports = [443]
    availability_zone_count        = 2
    allowed_web_cidrs              = ["203.0.113.0/24"]
    controller_outbound_tcp_ports  = [443]
    enable_nat_gateways            = true
    enable_network                 = true
  }

  assert {
    condition = (
      length(output.public_subnet_ids) == 2 &&
      length(output.private_subnet_ids) == 2 &&
      length(output.nat_gateway_ids) == 2
    )
    error_message = "The VPC must honor a supported two-AZ override."
  }

  assert {
    condition     = length(output.security_group_ids) == 4 && !contains(keys(output.security_group_ids), "ssh")
    error_message = "The VPC must never expose a public administrator SSH security group."
  }
}
