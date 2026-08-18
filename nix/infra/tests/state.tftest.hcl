mock_provider "aws" {
  mock_data "aws_caller_identity" {
    defaults = {
      account_id = "123456789012"
      arn        = "arn:aws:iam::123456789012:user/mock"
      user_id    = "AIDAMOCK"
    }
  }

  mock_data "aws_partition" {
    defaults = {
      partition = "aws"
    }
  }

  mock_data "aws_iam_policy_document" {
    defaults = {
      json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
    }
  }
}

run "protected_remote_state_contract" {
  command = plan

  assert {
    condition = (
      output.state_bucket_name == "lucidity-production-tofu-state-123456789012-us-east-2-an" &&
      output.access_log_bucket_name == "lucidity-production-tofu-logs-123456789012-us-east-2-an"
    )
    error_message = "State bootstrap must create deterministic account-regional state and access-log bucket names."
  }

  assert {
    condition = (
      output.security_controls.state_bucket_namespace == "account-regional" &&
      output.security_controls.state_force_destroy == false &&
      output.security_controls.access_log_namespace == "account-regional" &&
      output.security_controls.access_log_force_destroy == false
    )
    error_message = "State buckets must use the account-regional namespace and resist destructive removal."
  }

  assert {
    condition = (
      output.security_controls.state_versioning == "Enabled" &&
      output.security_controls.access_log_versioning == "Enabled" &&
      output.security_controls.default_encryption == "AES256" &&
      contains(output.security_controls.blocked_encryption_types, "SSE-C")
    )
    error_message = "State and audit buckets must be versioned, encrypted by default, and reject customer-provided encryption keys."
  }

  assert {
    condition = (
      output.security_controls.state_access_log_target == output.access_log_bucket_name &&
      output.security_controls.state_access_log_prefix == "state-bucket/" &&
      output.security_controls.state_abac == "Enabled" &&
      output.security_controls.access_log_abac == "Enabled"
    )
    error_message = "State access must be logged to the private audit bucket and both buckets must enable ABAC."
  }

  assert {
    condition = (
      output.backend_configuration.bucket == "lucidity-production-tofu-state-123456789012-us-east-2-an" &&
      output.backend_configuration.encrypt == true &&
      output.backend_configuration.key == "lucidity/production/terraform.tfstate" &&
      output.backend_configuration.region == "us-east-2" &&
      output.backend_configuration.use_lockfile == true
    )
    error_message = "The backend output must enable encrypted native S3 state locking without DynamoDB."
  }
}
