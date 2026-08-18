{stateRoot, ...}: let
  tf = expression: "\${${expression}}";
  resources = [
    "aws_s3_bucket.state"
    "aws_s3_bucket.access_logs"
    "aws_s3_bucket_versioning.state"
    "aws_s3_bucket_versioning.access_logs"
    "aws_s3_bucket_server_side_encryption_configuration.state"
    "aws_s3_bucket_server_side_encryption_configuration.access_logs"
    "aws_s3_bucket_abac.state"
    "aws_s3_bucket_abac.access_logs"
    "aws_s3_bucket_policy.state"
    "aws_s3_bucket_policy.access_logs"
    "aws_s3_bucket_logging.state"
    "aws_s3_bucket_lifecycle_configuration.state"
    "aws_s3_bucket_lifecycle_configuration.access_logs"
  ];
in {
  terraform = {
    required_version = ">= 1.10.0, < 2.0.0";
    backend.s3 = {};
    required_providers.aws = {
      source = "hashicorp/aws";
      version = "~> 6.0";
    };
  };
  variable = {
    aws_region = {
      type = "string";
      default = "us-east-2";
    };
    project_name = {
      type = "string";
      default = "lucidity";
    };
    environment = {
      type = "string";
      default = "production";
    };
    access_log_retention_days = {
      type = "number";
      default = 365;
    };
    tags = {
      type = "map(string)";
      default = {};
    };
  };
  provider.aws = {
    region = tf "var.aws_region";
    default_tags.tags = tf ''
      merge(
        {
          ManagedBy = "OpenTofu"
          Project = var.project_name
        },
        var.tags
      )
    '';
  };
  module.bootstrap = {
    source = "${stateRoot}";
    aws_region = tf "var.aws_region";
    project_name = tf "var.project_name";
    environment = tf "var.environment";
    access_log_retention_days = tf "var.access_log_retention_days";
    tags = tf "var.tags";
  };
  moved =
    map (address: {
      # OpenTofu's JSON syntax treats these specially as static traversals.
      # Interpolation templates are invalid in a moved block.
      from = address;
      to = "module.bootstrap.${address}";
    })
    resources;
  output = {
    state_bucket_name.value = tf "module.bootstrap.state_bucket_name";
    access_log_bucket_name.value = tf "module.bootstrap.access_log_bucket_name";
    backend_configuration.value = tf "module.bootstrap.backend_configuration";
    security_controls.value = tf "module.bootstrap.security_controls";
    backend_access_policy_json.value = tf "module.bootstrap.backend_access_policy_json";
  };
}
