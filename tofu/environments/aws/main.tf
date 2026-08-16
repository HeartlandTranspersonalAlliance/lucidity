locals {
  repository_names = {
    controller = "${var.repository_prefix}/controller"
    worker     = "${var.repository_prefix}/worker"
  }
  ec2_node_subnet_ids = var.enable_ec2_instances ? {
    for role in ["controller", "worker"] : role => module.network[0].public_subnet_ids[
      sort(keys(module.network[0].public_subnet_ids))[var.ec2_node_availability_zone_indices[role]]
    ]
  } : {}
}

module "account_cost_budget" {
  count  = var.enable_account_cost_budget ? 1 : 0
  source = "../../modules/account-cost-budget"

  actual_warning_percentage = var.account_cost_budget_warning_percentage
  environment               = var.environment
  annual_limit_usd          = var.account_annual_cost_limit_usd
  notification_email        = var.account_cost_budget_notification_email
  project_name              = var.vpc_name
  tags                      = var.tags
}

module "network" {
  count  = var.enable_network ? 1 : 0
  source = "../../modules/network"

  application_outbound_tcp_ports = var.application_outbound_tcp_ports
  availability_zone_count        = var.availability_zone_count
  allowed_web_cidrs              = var.allowed_web_cidrs
  controller_outbound_tcp_ports  = var.controller_outbound_tcp_ports
  enable_nat_gateways            = var.enable_nat_gateways
  environment                    = var.environment
  flow_log_retention_days        = var.flow_log_retention_days
  flow_log_traffic_type          = var.flow_log_traffic_type
  tags                           = var.tags
  vpc_cidr                       = var.vpc_cidr
  vpc_name                       = var.vpc_name
}

module "runtime_secrets" {
  count  = var.enable_runtime_secrets ? 1 : 0
  source = "../../modules/runtime-secrets"

  environment             = var.environment
  project_name            = var.vpc_name
  recovery_window_in_days = var.secret_recovery_window_in_days
  tags                    = var.tags
}

module "instance_management" {
  count  = var.enable_instance_management ? 1 : 0
  source = "../../modules/instance-management"

  controller_policy_arns = var.enable_runtime_secrets ? toset([
    module.runtime_secrets[0].controller_policy_arn,
  ]) : toset([])
  ecr_repository_arns = module.registry.repository_arns
  environment         = var.environment
  project_name        = var.vpc_name
  tags                = var.tags
}

module "registry" {
  source = "../../modules/ecr"

  repository_names = local.repository_names
}

module "github_oidc" {
  source = "../../modules/github-oidc"

  github_repository          = var.github_repository
  github_repository_owner_id = var.github_repository_owner_id
  github_repository_id       = var.github_repository_id
  github_branch              = var.github_publish_branch
  oidc_provider_arn          = var.github_oidc_provider_arn
  repository_arns            = toset(values(module.registry.repository_arns))
}

module "ami_import_validation" {
  source = "../../modules/ami-import-validation"

  aws_region                               = var.aws_region
  enable_launch_validation                 = var.enable_ami_launch_validation
  environment                              = var.environment
  github_branch                            = var.github_publish_branch
  github_repository                        = var.github_repository
  github_repository_owner_id               = var.github_repository_owner_id
  github_repository_id                     = var.github_repository_id
  launch_validation_instance_profile_names = var.enable_instance_management ? toset(values(module.instance_management[0].instance_profile_names)) : toset([])
  launch_validation_instance_type          = var.controller_instance_type
  launch_validation_role_arns              = var.enable_instance_management ? toset(values(module.instance_management[0].role_arns)) : toset([])
  launch_validation_security_group_ids = var.enable_network ? toset([
    module.network[0].security_group_ids.application,
    module.network[0].security_group_ids.controller,
  ]) : toset([])
  launch_validation_subnet_ids = var.enable_network ? toset(values(
    module.network[0].public_subnet_ids,
  )) : toset([])
  oidc_provider_arn = module.github_oidc.oidc_provider_arn
  project_name      = var.vpc_name
  source_repository_arns = toset([
    module.registry.repository_arns.controller,
    module.registry.repository_arns.worker,
  ])
  tags = var.tags
}

module "deployment_validation" {
  source = "../../modules/deployment-validation"

  aws_region                 = var.aws_region
  environment                = var.environment
  github_branch              = var.github_publish_branch
  github_repository          = var.github_repository
  github_repository_owner_id = var.github_repository_owner_id
  github_repository_id       = var.github_repository_id
  oidc_provider_arn          = module.github_oidc.oidc_provider_arn
  project_name               = var.vpc_name
  tags                       = var.tags
}

module "ec2_launch_templates" {
  count  = var.enable_ec2_launch_templates ? 1 : 0
  source = "../../modules/ec2-launch-templates"

  ami_ids = {
    controller = var.controller_ami_id
    worker     = var.worker_ami_id
  }
  controller_runtime_secret_name = module.runtime_secrets[0].secret_name
  environment                    = var.environment
  instance_profile_names = {
    controller = module.instance_management[0].instance_profile_names.controller
    worker     = module.instance_management[0].instance_profile_names.worker
  }
  instance_types = {
    controller = var.controller_instance_type
    worker     = var.worker_instance_type
  }
  node_names              = var.ec2_node_names
  project_name            = var.vpc_name
  root_volume_kms_key_arn = module.ami_import_validation.snapshot_kms_key_arn
  root_volume_sizes = {
    controller = var.controller_root_volume_size_gib
    worker     = var.worker_root_volume_size_gib
  }
  security_group_ids = module.network[0].security_group_ids
  tags               = var.tags
}

module "ec2_nodes" {
  count  = var.enable_ec2_instances ? 1 : 0
  source = "../../modules/ec2-nodes"

  enable_termination_protection = var.enable_ec2_termination_protection
  environment                   = var.environment
  launch_template_ids           = module.ec2_launch_templates[0].launch_template_ids
  launch_template_versions      = module.ec2_launch_templates[0].launch_template_latest_versions
  node_names                    = var.ec2_node_names
  project_name                  = var.vpc_name
  subnet_ids                    = local.ec2_node_subnet_ids
  tags                          = var.tags
}

module "cloudflare_dns" {
  count  = var.enable_cloudflare_dns ? 1 : 0
  source = "../../modules/cloudflare-dns"

  origin_ipv4 = module.ec2_nodes[0].public_ips
  records     = var.cloudflare_dns_records
  zone_id     = var.cloudflare_zone_id
  zone_name   = var.cloudflare_zone_name
}

module "node_backups" {
  count  = var.enable_node_backups ? 1 : 0
  source = "../../modules/node-backups"

  environment        = var.environment
  instance_arns      = module.ec2_nodes[0].instance_arns
  instance_role_arns = module.instance_management[0].role_arns
  kms_key_arn        = module.ami_import_validation.snapshot_kms_key_arn
  project_name       = var.vpc_name
  retention_days     = var.node_backup_retention_days
  tags               = var.tags
}

module "node_monitoring" {
  count  = var.enable_node_monitoring ? 1 : 0
  source = "../../modules/node-monitoring"

  aws_region         = var.aws_region
  environment        = var.environment
  instance_ids       = module.ec2_nodes[0].instance_ids
  notification_email = var.node_alarm_notification_email
  project_name       = var.vpc_name
  tags               = var.tags
}
