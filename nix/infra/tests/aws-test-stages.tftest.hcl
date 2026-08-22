mock_provider "aws" {
  mock_resource "aws_cloudwatch_log_group" {
    defaults = {
      arn = "arn:aws:logs:us-east-2:123456789012:log-group:/vpc/lucidity-test/flow-logs"
    }
  }

  mock_resource "aws_iam_role" {
    defaults = {
      arn = "arn:aws:iam::123456789012:role/lucidity-test-mock-role"
    }
  }

  mock_resource "aws_iam_instance_profile" {
    defaults = {
      arn = "arn:aws:iam::123456789012:instance-profile/lucidity-test-profile"
    }
  }

  mock_resource "aws_iam_policy" {
    defaults = {
      arn = "arn:aws:iam::123456789012:policy/lucidity-test-policy"
    }
  }

  mock_resource "aws_instance" {
    defaults = {
      availability_zone = "us-east-2a"
      arn               = "arn:aws:ec2:us-east-2:123456789012:instance/i-0123456789abcdef0"
      id                = "i-0123456789abcdef0"
      private_ip        = "10.21.0.10"
    }
  }

  mock_resource "aws_eip" {
    defaults = {
      id        = "eipalloc-0123456789abcdef0"
      public_ip = "198.51.100.20"
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

  mock_resource "aws_subnet" {
    defaults = {
      id = "subnet-0123456789abcdef0"
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
      arn = "arn:aws:secretsmanager:us-east-2:123456789012:secret:lucidity/test/mock-AbCdEf"
    }
  }

  mock_resource "aws_s3_bucket" {
    defaults = {
      arn = "arn:aws:s3:::lucidity-test-mock"
    }
  }

  mock_resource "aws_backup_plan" {
    defaults = {
      id = "lucidity-test-backup-plan"
    }
  }

  mock_resource "aws_backup_vault" {
    defaults = {
      arn = "arn:aws:backup:us-east-2:123456789012:backup-vault:lucidity-test-nodes"
    }
  }

  mock_data "aws_availability_zones" {
    defaults = {
      names    = ["us-east-2a", "us-east-2b"]
      zone_ids = ["use2-az1", "use2-az2"]
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

mock_provider "cloudflare" {
  mock_resource "cloudflare_dns_record" {
    defaults = {
      id = "lucidity-test-dns"
    }
  }
}

variables {
  github_oidc_provider_arn    = "arn:aws:iam::123456789012:oidc-provider/token.actions.githubusercontent.com"
  shared_snapshot_kms_key_arn = "arn:aws:kms:us-east-2:123456789012:key/aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
  state_bucket_name           = "lucidity-test-state-123456789012-us-east-2"
  shared_ecr_repository_arns = {
    controller = "arn:aws:ecr:us-east-2:123456789012:repository/lucidity/bootc/controller"
    worker     = "arn:aws:ecr:us-east-2:123456789012:repository/lucidity/bootc/worker"
  }
  shared_ecr_repository_names = {
    controller = "lucidity/bootc/controller"
    worker     = "lucidity/bootc/worker"
  }
  shared_ecr_repository_urls = {
    controller = "123456789012.dkr.ecr.us-east-2.amazonaws.com/lucidity/bootc/controller"
    worker     = "123456789012.dkr.ecr.us-east-2.amazonaws.com/lucidity/bootc/worker"
  }
}

run "test_foundation_is_isolated" {
  command = plan

  assert {
    condition = (
      output.deployment_environment == "test" &&
      output.deployment_release == "v0.4.0" &&
      output.deployment_stage == "foundation" &&
      output.account_security_baseline == null &&
      output.account_cost_budget_arn == null &&
      length(output.public_subnet_ids) == 2 &&
      length(output.ec2_instance_ids) == 0 &&
      length(output.cloudflare_dns_records) == 0 &&
      output.node_backup_plan_id == null &&
      output.public_web_ingress_enabled == false
    )
    error_message = "The test foundation must create only isolated test prerequisites without shared baselines, nodes, DNS, or backups."
  }

  assert {
    condition = (
      output.controller_runtime_secret_name == "lucidity/test/controller-runtime" &&
      output.runtime_secret_names.monitoring == "lucidity/test/monitoring-tokens" &&
      output.runtime_secret_names.restic == "lucidity/test/restic" &&
      output.github_infra_plan_role_arn == "arn:aws:iam::123456789012:role/lucidity-test-mock-role" &&
      output.github_infra_apply_role_arn == "arn:aws:iam::123456789012:role/lucidity-test-mock-role"
    )
    error_message = "The test foundation must expose only test-scoped secret containers and OIDC roles."
  }
}

run "test_compute_has_exactly_two_nodes" {
  command = plan

  variables {
    controller_ami_id = "ami-01111111111111111"
    deployment_stage  = "compute"
    worker_ami_id     = "ami-02222222222222222"
  }

  assert {
    condition = (
      length(output.selected_ami_ids) == 2 &&
      length(output.ec2_instance_ids) == 2 &&
      length(output.cloudflare_dns_records) == 0 &&
      output.node_backup_plan_id == null &&
      output.public_web_ingress_enabled == false
    )
    error_message = "The compute stage must launch one pinned controller and worker without exposing DNS or web ingress."
  }
}

run "test_edge_exposes_only_declared_dns" {
  command = plan

  variables {
    cloudflare_zone_id = "4616a45d9d8f6dd9a0ff5b5e739bdf6d"
    controller_ami_id  = "ami-01111111111111111"
    deployment_stage   = "edge"
    worker_ami_id      = "ami-02222222222222222"
  }

  assert {
    condition = (
      length(output.cloudflare_dns_records) == 7 &&
      output.node_backup_plan_id == "lucidity-test-backup-plan" &&
      output.public_web_ingress_enabled == true
    )
    error_message = "The edge stage must publish the seven test records and enable backups and reviewed web ingress."
  }
}

run "test_quarantine_removes_public_edge" {
  command = plan

  variables {
    controller_ami_id = "ami-01111111111111111"
    deployment_stage  = "quarantine"
    worker_ami_id     = "ami-02222222222222222"
  }

  assert {
    condition = (
      length(output.ec2_instance_ids) == 2 &&
      length(output.cloudflare_dns_records) == 0 &&
      output.node_backup_plan_id == "lucidity-test-backup-plan" &&
      output.public_web_ingress_enabled == false
    )
    error_message = "Quarantine must retain test nodes, SSM-era infrastructure, and backups while removing DNS and public web ingress."
  }
}
