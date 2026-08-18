{
  hostFacts,
  lib,
  moduleRoot,
  ...
}: let
  tf = expression: "\${${expression}}";
  cloudflareIPv4 = [
    "173.245.48.0/20"
    "103.21.244.0/22"
    "103.22.200.0/22"
    "103.31.4.0/22"
    "141.101.64.0/18"
    "108.162.192.0/18"
    "190.93.240.0/20"
    "188.114.96.0/20"
    "197.234.240.0/22"
    "198.41.128.0/17"
    "162.158.0.0/15"
    "104.16.0.0/13"
    "104.24.0.0/14"
    "172.64.0.0/13"
    "131.0.72.0/22"
  ];
  boolVariable = description: default: {
    inherit description default;
    type = "bool";
  };
  stringVariable = description: default:
    {
      inherit description;
      type = "string";
    }
    // lib.optionalAttrs (default != null) {inherit default;};
  numberVariable = description: default: {
    inherit description default;
    type = "number";
  };
in {
  terraform = {
    required_version = ">= 1.10.0, < 2.0.0";
    backend.s3 = {};
    required_providers = {
      aws = {
        source = "hashicorp/aws";
        version = "~> 6.0";
      };
      cloudflare = {
        source = "cloudflare/cloudflare";
        version = "~> 5.23";
      };
    };
  };

  provider = {
    aws = {
      region = tf "var.aws_region";
      default_tags = [
        {
          tags = tf "merge({ ManagedBy = \"OpenTofu\", Project = \"lucidity\" }, var.tags)";
        }
      ];
    };
    cloudflare = {};
  };

  variable = {
    aws_region = stringVariable "AWS region for the deployment." "us-east-2";
    environment = stringVariable "Environment tag." "production";
    vpc_name = stringVariable "Stable project and VPC name." "lucidity";
    vpc_cidr = stringVariable "Production VPC CIDR." "10.20.0.0/16";
    availability_zone_count = numberVariable "Number of VPC Availability Zones." 3;
    enable_nat_gateways = boolVariable "Create NAT Gateways." false;
    enable_network = boolVariable "Create the VPC and security controls." false;
    enable_runtime_secrets = boolVariable "Create the bundled controller runtime secret." false;
    enable_instance_management = boolVariable "Create SSM EC2 instance profiles." false;
    enable_ami_launch_validation = boolVariable "Permit disposable AMI launch validation." false;
    enable_ec2_launch_templates = boolVariable "Create hardened launch templates." false;
    enable_ec2_instances = boolVariable "Launch production nodes." false;
    enable_ec2_termination_protection = boolVariable "Protect production nodes from API termination." true;
    enable_cloudflare_dns = boolVariable "Manage Cloudflare DNS records." false;
    enable_node_backups = boolVariable "Create daily AWS Backup recovery points." false;
    enable_node_monitoring = boolVariable "Create basic-monitoring alarms." false;
    enable_account_security_baseline = boolVariable "Enable regional account security, audit, and posture controls." false;
    enable_account_cost_budget = boolVariable "Create the monitoring-only annual account budget." false;
    enable_openbao = boolVariable "Create OpenBao KMS auto-unseal resources." false;
    account_annual_cost_limit_usd = numberVariable "Annual monitoring-only account budget." 1100;
    account_cost_budget_warning_percentage = numberVariable "Actual-spend early warning percentage." 80;
    account_cost_budget_notification_email = stringVariable "Budget notification email." null;
    node_alarm_notification_email = stringVariable "Node alarm email." null;
    node_backup_retention_days = numberVariable "Daily backup retention." 7;
    flow_log_retention_days = numberVariable "Rejected flow-log retention." 30;
    flow_log_traffic_type = stringVariable "VPC flow traffic type." "REJECT";
    secret_recovery_window_in_days = numberVariable "Secrets Manager deletion recovery window." 30;
    deployment_architecture = stringVariable "Initial production architecture." "amd64";
    controller_instance_type = stringVariable "Controller EC2 type." hostFacts.controller.instanceType;
    worker_instance_type = stringVariable "Worker EC2 type." hostFacts.worker.instanceType;
    controller_root_volume_size_gib = numberVariable "Controller gp3 size." hostFacts.controller.rootVolumeGiB;
    worker_root_volume_size_gib = numberVariable "Worker gp3 size." hostFacts.worker.rootVolumeGiB;
    controller_ami_id = stringVariable "Pinned controller AMI." null;
    worker_ami_id = stringVariable "Pinned worker AMI." null;
    cloudflare_zone_id = stringVariable "Cloudflare zone ID." null;
    cloudflare_zone_name = stringVariable "Cloudflare zone name." "heartlandta.org";
    github_repository = stringVariable "GitHub repository." "HeartlandTranspersonalAlliance/lucidity";
    github_repository_owner_id = stringVariable "Immutable GitHub owner ID." "256628390";
    github_repository_id = stringVariable "Immutable GitHub repository ID." "1333819830";
    github_publish_branch = stringVariable "GitHub publishing branch." "main";
    github_oidc_provider_arn = stringVariable "Existing GitHub OIDC provider ARN." null;
    repository_prefix = stringVariable "ECR repository prefix." "lucidity/bootc";
    root_volume_kms_key_arn = stringVariable "Optional explicit root volume KMS key." null;
    tags = {
      description = "Additional AWS tags.";
      type = "map(string)";
      default = {};
    };
    allowed_web_cidrs = {
      description = "Current Cloudflare IPv4 origin ranges.";
      type = "set(string)";
      default = cloudflareIPv4;
    };
    controller_outbound_tcp_ports = {
      description = "Controller Internet TCP egress.";
      type = "set(number)";
      default = [443];
    };
    application_outbound_tcp_ports = {
      description = "Worker Internet TCP egress.";
      type = "set(number)";
      default = [
        443
        8448
      ];
    };
    ec2_node_names = {
      description = "Stable production node names.";
      type = "map(string)";
      default = {
        controller = "coolify-controller";
        worker = "coolify-worker-01";
      };
    };
    ec2_node_availability_zone_indices = {
      description = "Both nodes remain in one AZ.";
      type = "map(number)";
      default = {
        controller = 0;
        worker = 0;
      };
    };
    cloudflare_dns_records = {
      description = "Web records stay proxied; mesh discovery is DNS-only.";
      type = "map(object({ role = string, proxied = optional(bool, true) }))";
      default = {
        coolify = {
          role = "controller";
          proxied = true;
        };
        apps = {
          role = "worker";
          proxied = true;
        };
        "*.apps" = {
          role = "worker";
          proxied = true;
        };
        matrix = {
          role = "worker";
          proxied = true;
        };
        mesh = {
          role = "controller";
          proxied = false;
        };
      };
    };
  };

  locals = {
    repository_names = {
      controller = (tf "var.repository_prefix") + "/controller";
      worker = (tf "var.repository_prefix") + "/worker";
    };
    ec2_node_subnet_ids = tf "var.enable_ec2_instances ? { for role in [\"controller\", \"worker\"] : role => module.network[0].public_subnet_ids[sort(keys(module.network[0].public_subnet_ids))[var.ec2_node_availability_zone_indices[role]]] } : {}";
  };

  resource = {
    aws_kms_key.openbao_unseal = {
      count = tf "var.enable_openbao ? 1 : 0";
      description = "Lucidity OpenBao auto-unseal key";
      enable_key_rotation = true;
      deletion_window_in_days = 30;
      tags = tf "merge({ Name = \"lucidity-production-openbao-unseal\" }, var.tags)";
    };
    aws_kms_alias.openbao_unseal = {
      count = tf "var.enable_openbao ? 1 : 0";
      name = "alias/lucidity-production-openbao-unseal";
      target_key_id = tf "aws_kms_key.openbao_unseal[0].key_id";
    };
    aws_iam_policy.openbao_unseal = {
      count = tf "var.enable_openbao ? 1 : 0";
      name = "lucidity-production-openbao-unseal";
      description = "Encrypt, decrypt, and describe only the Lucidity OpenBao auto-unseal key";
      policy = tf "jsonencode({ Version = \"2012-10-17\", Statement = [{ Sid = \"UseOpenBaoUnsealKey\", Effect = \"Allow\", Action = [\"kms:Encrypt\", \"kms:Decrypt\", \"kms:DescribeKey\"], Resource = aws_kms_key.openbao_unseal[0].arn }] })";
      tags = tf "var.tags";
    };
  };

  module = {
    account_security_baseline = {
      count = tf "var.enable_account_security_baseline ? 1 : 0";
      source = "${moduleRoot}/account-security-baseline";
      environment = tf "var.environment";
      project_name = tf "var.vpc_name";
      tags = tf "var.tags";
    };
    account_cost_budget = {
      count = tf "var.enable_account_cost_budget ? 1 : 0";
      source = "${moduleRoot}/account-cost-budget";
      actual_warning_percentage = tf "var.account_cost_budget_warning_percentage";
      environment = tf "var.environment";
      annual_limit_usd = tf "var.account_annual_cost_limit_usd";
      notification_email = tf "var.account_cost_budget_notification_email";
      project_name = tf "var.vpc_name";
      tags = tf "var.tags";
    };
    network = {
      count = tf "var.enable_network ? 1 : 0";
      source = "${moduleRoot}/network";
      application_outbound_tcp_ports = tf "var.application_outbound_tcp_ports";
      availability_zone_count = tf "var.availability_zone_count";
      allowed_web_cidrs = tf "var.allowed_web_cidrs";
      controller_outbound_tcp_ports = tf "var.controller_outbound_tcp_ports";
      enable_nat_gateways = tf "var.enable_nat_gateways";
      environment = tf "var.environment";
      flow_log_retention_days = tf "var.flow_log_retention_days";
      flow_log_traffic_type = tf "var.flow_log_traffic_type";
      nebula_udp_port = 4242;
      tags = tf "var.tags";
      vpc_cidr = tf "var.vpc_cidr";
      vpc_name = tf "var.vpc_name";
    };
    runtime_secrets = {
      count = tf "var.enable_runtime_secrets ? 1 : 0";
      source = "${moduleRoot}/runtime-secrets";
      environment = tf "var.environment";
      project_name = tf "var.vpc_name";
      recovery_window_in_days = tf "var.secret_recovery_window_in_days";
      tags = tf "var.tags";
    };
    registry = {
      source = "${moduleRoot}/ecr";
      repository_names = {
        controller = (tf "var.repository_prefix") + "/controller";
        worker = (tf "var.repository_prefix") + "/worker";
      };
    };
    instance_management = {
      count = tf "var.enable_instance_management ? 1 : 0";
      source = "${moduleRoot}/instance-management";
      controller_policies = tf "merge(var.enable_runtime_secrets ? { runtime_secrets = module.runtime_secrets[0].controller_policy_arn } : {}, var.enable_openbao ? { openbao_unseal = aws_iam_policy.openbao_unseal[0].arn } : {})";
      ecr_repository_arns = tf "module.registry.repository_arns";
      environment = tf "var.environment";
      project_name = tf "var.vpc_name";
      tags = tf "var.tags";
    };
    github_oidc = {
      source = "${moduleRoot}/github-oidc";
      github_repository = tf "var.github_repository";
      github_repository_owner_id = tf "var.github_repository_owner_id";
      github_repository_id = tf "var.github_repository_id";
      github_branch = tf "var.github_publish_branch";
      oidc_provider_arn = tf "var.github_oidc_provider_arn";
      repository_arns = tf "toset(values(module.registry.repository_arns))";
    };
    ami_import_validation = {
      source = "${moduleRoot}/ami-import-validation";
      aws_region = tf "var.aws_region";
      enable_launch_validation = tf "var.enable_ami_launch_validation";
      environment = tf "var.environment";
      github_branch = tf "var.github_publish_branch";
      github_repository = tf "var.github_repository";
      github_repository_owner_id = tf "var.github_repository_owner_id";
      github_repository_id = tf "var.github_repository_id";
      launch_validation_instance_profile_names = tf "var.enable_instance_management ? toset(values(module.instance_management[0].instance_profile_names)) : toset([])";
      launch_validation_instance_type = tf "var.controller_instance_type";
      launch_validation_role_arns = tf "var.enable_instance_management ? toset(values(module.instance_management[0].role_arns)) : toset([])";
      launch_validation_security_group_ids = tf "var.enable_network ? toset([module.network[0].security_group_ids.application, module.network[0].security_group_ids.controller]) : toset([])";
      launch_validation_subnet_ids = tf "var.enable_network ? toset(values(module.network[0].public_subnet_ids)) : toset([])";
      oidc_provider_arn = tf "module.github_oidc.oidc_provider_arn";
      project_name = tf "var.vpc_name";
      source_repository_arns = tf "toset([module.registry.repository_arns.controller, module.registry.repository_arns.worker])";
      tags = tf "var.tags";
    };
    deployment_validation = {
      source = "${moduleRoot}/deployment-validation";
      aws_region = tf "var.aws_region";
      environment = tf "var.environment";
      github_branch = tf "var.github_publish_branch";
      github_repository = tf "var.github_repository";
      github_repository_owner_id = tf "var.github_repository_owner_id";
      github_repository_id = tf "var.github_repository_id";
      oidc_provider_arn = tf "module.github_oidc.oidc_provider_arn";
      project_name = tf "var.vpc_name";
      tags = tf "var.tags";
    };
    ec2_launch_templates = {
      count = tf "var.enable_ec2_launch_templates ? 1 : 0";
      source = "${moduleRoot}/ec2-launch-templates";
      ami_ids = {
        controller = tf "var.controller_ami_id";
        worker = tf "var.worker_ami_id";
      };
      controller_runtime_secret_name = tf "module.runtime_secrets[0].secret_name";
      environment = tf "var.environment";
      instance_profile_names = {
        controller = tf "module.instance_management[0].instance_profile_names.controller";
        worker = tf "module.instance_management[0].instance_profile_names.worker";
      };
      instance_types = {
        controller = tf "var.controller_instance_type";
        worker = tf "var.worker_instance_type";
      };
      node_names = tf "var.ec2_node_names";
      project_name = tf "var.vpc_name";
      root_volume_kms_key_arn = tf "module.ami_import_validation.snapshot_kms_key_arn";
      root_volume_sizes = {
        controller = tf "var.controller_root_volume_size_gib";
        worker = tf "var.worker_root_volume_size_gib";
      };
      security_group_ids = tf "module.network[0].security_group_ids";
      tags = tf "var.tags";
    };
    ec2_nodes = {
      count = tf "var.enable_ec2_instances ? 1 : 0";
      source = "${moduleRoot}/ec2-nodes";
      enable_termination_protection = tf "var.enable_ec2_termination_protection";
      environment = tf "var.environment";
      launch_template_ids = tf "module.ec2_launch_templates[0].launch_template_ids";
      launch_template_versions = tf "module.ec2_launch_templates[0].launch_template_latest_versions";
      node_names = tf "var.ec2_node_names";
      project_name = tf "var.vpc_name";
      subnet_ids = tf "local.ec2_node_subnet_ids";
      tags = tf "var.tags";
    };
    cloudflare_dns = {
      count = tf "var.enable_cloudflare_dns ? 1 : 0";
      source = "${moduleRoot}/cloudflare-dns";
      origin_ipv4 = tf "module.ec2_nodes[0].public_ips";
      records = tf "var.cloudflare_dns_records";
      zone_id = tf "var.cloudflare_zone_id";
      zone_name = tf "var.cloudflare_zone_name";
    };
    node_backups = {
      count = tf "var.enable_node_backups ? 1 : 0";
      source = "${moduleRoot}/node-backups";
      environment = tf "var.environment";
      instance_arns = tf "module.ec2_nodes[0].instance_arns";
      instance_role_arns = tf "module.instance_management[0].role_arns";
      kms_key_arn = tf "module.ami_import_validation.snapshot_kms_key_arn";
      project_name = tf "var.vpc_name";
      retention_days = tf "var.node_backup_retention_days";
      tags = tf "var.tags";
    };
    node_monitoring = {
      count = tf "var.enable_node_monitoring ? 1 : 0";
      source = "${moduleRoot}/node-monitoring";
      aws_region = tf "var.aws_region";
      environment = tf "var.environment";
      instance_ids = tf "module.ec2_nodes[0].instance_ids";
      notification_email = tf "var.node_alarm_notification_email";
      project_name = tf "var.vpc_name";
      tags = tf "var.tags";
    };
  };

  output = {
    account_security_baseline = {
      value = tf "var.enable_account_security_baseline ? module.account_security_baseline[0].summary : null";
    };
    account_cost_budget_arn = {
      value = tf "var.enable_account_cost_budget ? module.account_cost_budget[0].arn : null";
    };
    account_cost_budget_name = {
      value = tf "var.enable_account_cost_budget ? module.account_cost_budget[0].name : null";
    };
    account_cost_budget_settings = {
      value = tf "var.enable_account_cost_budget ? module.account_cost_budget[0].settings : null";
    };
    ami_launch_validation_enabled = {
      value = tf "var.enable_ami_launch_validation";
    };
    ami_snapshot_kms_key_arn = {
      value = tf "module.ami_import_validation.snapshot_kms_key_arn";
    };
    ami_test_instance_profile_name = {
      value = tf "var.enable_ami_launch_validation && var.enable_instance_management ? module.instance_management[0].instance_profile_names.worker : null";
    };
    ami_test_instance_profile_names = {
      value = tf "var.enable_ami_launch_validation && var.enable_instance_management ? module.instance_management[0].instance_profile_names : {}";
    };
    ami_test_instance_type = {
      value = tf "var.enable_ami_launch_validation ? var.controller_instance_type : null";
    };
    ami_test_security_group_id = {
      value = tf "var.enable_ami_launch_validation && var.enable_network ? module.network[0].security_group_ids.application : null";
    };
    ami_test_security_group_ids = {
      value = tf "var.enable_ami_launch_validation && var.enable_network ? { controller = module.network[0].security_group_ids.controller, worker = module.network[0].security_group_ids.application } : {}";
    };
    ami_test_subnet_id = {
      value = tf "var.enable_ami_launch_validation && var.enable_network ? module.network[0].public_subnet_ids[sort(keys(module.network[0].public_subnet_ids))[0]] : null";
    };
    annual_budget_limit_usd = {
      value = tf "var.account_annual_cost_limit_usd";
    };
    availability_zones = {
      value = tf "var.enable_network ? module.network[0].availability_zones : []";
    };
    cloudflare_dns_records = {
      value = tf "var.enable_cloudflare_dns ? module.cloudflare_dns[0].records : {}";
    };
    controller_instance_profile_name = {
      value = tf "var.enable_instance_management ? module.instance_management[0].instance_profile_names.controller : null";
    };
    controller_instance_type = {
      value = tf "var.controller_instance_type";
    };
    controller_runtime_role_arn = {
      value = tf "var.enable_instance_management ? module.instance_management[0].role_arns.controller : null";
    };
    controller_runtime_secret_arn = {
      value = tf "var.enable_runtime_secrets ? module.runtime_secrets[0].secret_arn : null";
    };
    controller_runtime_secret_name = {
      value = tf "var.enable_runtime_secrets ? module.runtime_secrets[0].secret_name : null";
    };
    controller_runtime_secret_reference_pattern = {
      value = tf "var.enable_runtime_secrets ? module.runtime_secrets[0].dynamic_reference_pattern : null";
    };
    deployment_architecture = {
      value = tf "var.deployment_architecture";
    };
    ecr_repository_arns = {
      value = tf "module.registry.repository_arns";
    };
    ecr_repository_names = {
      value = tf "module.registry.repository_names";
    };
    ecr_repository_urls = {
      value = tf "module.registry.repository_urls";
    };
    ec2_availability_zones = {
      value = tf "var.enable_ec2_instances ? module.ec2_nodes[0].availability_zones : {}";
    };
    ec2_detailed_monitoring_enabled = {
      value = tf "var.enable_ec2_launch_templates ? module.ec2_launch_templates[0].detailed_monitoring_enabled : {}";
    };
    ec2_elastic_ip_allocation_ids = {
      value = tf "var.enable_ec2_instances ? module.ec2_nodes[0].elastic_ip_allocation_ids : {}";
    };
    ec2_instance_ids = {
      value = tf "var.enable_ec2_instances ? module.ec2_nodes[0].instance_ids : {}";
    };
    ec2_instance_settings = {
      value = tf "var.enable_ec2_instances ? module.ec2_nodes[0].instance_settings : {}";
    };
    ec2_launch_template_ids = {
      value = tf "var.enable_ec2_launch_templates ? module.ec2_launch_templates[0].launch_template_ids : {}";
    };
    ec2_launch_template_latest_versions = {
      value = tf "var.enable_ec2_launch_templates ? module.ec2_launch_templates[0].launch_template_latest_versions : {}";
    };
    ec2_private_ips = {
      value = tf "var.enable_ec2_instances ? module.ec2_nodes[0].private_ips : {}";
    };
    ec2_public_ips = {
      value = tf "var.enable_ec2_instances ? module.ec2_nodes[0].public_ips : {}";
    };
    ec2_root_volume_settings = {
      value = tf "var.enable_ec2_launch_templates ? module.ec2_launch_templates[0].root_volume_settings : {}";
    };
    github_ami_audit_role_arn = {
      value = tf "module.ami_import_validation.github_audit_role_arn";
    };
    github_ami_validation_role_arn = {
      value = tf "module.ami_import_validation.github_role_arn";
    };
    github_ami_validation_subject = {
      value = tf "module.ami_import_validation.github_subject";
    };
    github_deployment_validation_role_arn = {
      value = tf "module.deployment_validation.github_role_arn";
    };
    github_deployment_validation_subject = {
      value = tf "module.deployment_validation.github_subject";
    };
    github_oidc_provider_arn = {
      value = tf "module.github_oidc.oidc_provider_arn";
    };
    github_oidc_subject = {
      value = tf "module.github_oidc.trusted_subject";
    };
    github_publish_role_arn = {
      value = tf "module.github_oidc.publish_role_arn";
    };
    internet_gateway_id = {
      value = tf "var.enable_network ? module.network[0].internet_gateway_id : null";
    };
    nat_gateway_ids = {
      value = tf "var.enable_network ? module.network[0].nat_gateway_ids : {}";
    };
    nat_gateway_public_ips = {
      value = tf "var.enable_network ? module.network[0].nat_gateway_public_ips : {}";
    };
    node_alarm_email_subscription_arn = {
      value = tf "var.enable_node_monitoring ? module.node_monitoring[0].email_subscription_arn : null";
    };
    node_alarm_names = {
      value = tf "var.enable_node_monitoring ? module.node_monitoring[0].alarm_names : {}";
    };
    node_alarm_notification_kms_key_arn = {
      value = tf "var.enable_node_monitoring ? module.node_monitoring[0].notification_kms_key_arn : null";
    };
    node_alarm_notification_topic_arn = {
      value = tf "var.enable_node_monitoring ? module.node_monitoring[0].notification_topic_arn : null";
    };
    node_alarm_settings = {
      value = tf "var.enable_node_monitoring ? module.node_monitoring[0].settings : null";
    };
    node_backup_plan_id = {
      value = tf "var.enable_node_backups ? module.node_backups[0].plan_id : null";
    };
    node_backup_retention_days = {
      value = tf "var.enable_node_backups ? module.node_backups[0].retention_days : null";
    };
    node_backup_service_role_arn = {
      value = tf "var.enable_node_backups ? module.node_backups[0].service_role_arn : null";
    };
    node_backup_settings = {
      value = tf "var.enable_node_backups ? module.node_backups[0].settings : null";
    };
    node_backup_vault_arn = {
      value = tf "var.enable_node_backups ? module.node_backups[0].vault_arn : null";
    };
    node_restore_service_role_arn = {
      value = tf "var.enable_node_backups ? module.node_backups[0].restore_role_arn : null";
    };
    openbao_unseal_kms_key_arn = {
      value = tf "var.enable_openbao ? aws_kms_key.openbao_unseal[0].arn : null";
    };
    private_subnet_ids = {
      value = tf "var.enable_network ? module.network[0].private_subnet_ids : {}";
    };
    public_subnet_ids = {
      value = tf "var.enable_network ? module.network[0].public_subnet_ids : {}";
    };
    runtime_secrets_kms_key_id = {
      value = tf "var.enable_runtime_secrets ? module.runtime_secrets[0].kms_key_id : null";
    };
    security_group_ids = {
      value = tf "var.enable_network ? module.network[0].security_group_ids : {}";
    };
    selected_ami_ids = {
      value = tf "var.enable_ec2_launch_templates ? module.ec2_launch_templates[0].selected_ami_ids : {}";
    };
    ses_pricing_plan = {
      value = "NONE";
      description = "Enforced and verified by lucidity infra apply through the SES v2 account-pricing API.";
    };
    vpc_cidr = {
      value = tf "var.enable_network ? module.network[0].vpc_cidr : null";
    };
    vpc_flow_log_group_name = {
      value = tf "var.enable_network ? module.network[0].flow_log_group_name : null";
    };
    vpc_flow_log_id = {
      value = tf "var.enable_network ? module.network[0].flow_log_id : null";
    };
    vpc_flow_log_settings = {
      value = tf "var.enable_network ? module.network[0].flow_log_settings : null";
    };
    vpc_id = {
      value = tf "var.enable_network ? module.network[0].vpc_id : null";
    };
    worker_instance_profile_name = {
      value = tf "var.enable_instance_management ? module.instance_management[0].instance_profile_names.worker : null";
    };
    worker_instance_type = {
      value = tf "var.worker_instance_type";
    };
    worker_runtime_role_arn = {
      value = tf "var.enable_instance_management ? module.instance_management[0].role_arns.worker : null";
    };
  };
}
