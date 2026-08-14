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
    condition     = output.github_oidc_subject == "repo:HeartlandTranspersonalAlliance/lucidity:ref:refs/heads/main"
    error_message = "The GitHub OIDC trust must remain restricted to this repository's main branch."
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
    condition     = output.ami_import_bucket_name == "lucidity-ami-import-123456789012-us-east-2"
    error_message = "AMI validation must use the deterministic account- and region-scoped import bucket."
  }

  assert {
    condition     = output.github_ami_validation_subject == "repo:HeartlandTranspersonalAlliance/lucidity:ref:refs/heads/main"
    error_message = "AMI import credentials must remain restricted to this repository's main branch."
  }

  assert {
    condition     = output.vmimport_role_name == "lucidity-vmimport"
    error_message = "The AMI workflow must pass the project-scoped VM Import Export role explicitly."
  }
}

run "ec2_foundation_contract" {
  command = plan

  variables {
    enable_network         = true
    enable_runtime_secrets = true
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
    error_message = "The future controller must receive the least-privilege runtime instance profile."
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

run "two_az_network_and_restricted_access" {
  command = plan

  variables {
    availability_zone_count    = 2
    allowed_web_cidrs          = ["203.0.113.0/24"]
    controller_bootstrap_cidrs = ["198.51.100.10/32"]
    enable_nat_gateways        = true
    enable_network             = true
    enable_ssh_access          = true
    ssh_allowed_cidrs          = ["198.51.100.10/32"]
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
    condition     = contains(keys(output.security_group_ids), "ssh")
    error_message = "Enabling restricted SSH must expose the SSH security group output."
  }
}
