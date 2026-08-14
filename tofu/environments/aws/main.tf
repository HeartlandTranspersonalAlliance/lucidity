locals {
  repository_names = {
    controller = "${var.repository_prefix}/controller"
    worker     = "${var.repository_prefix}/worker"
  }
}

module "network" {
  count  = var.enable_network ? 1 : 0
  source = "../../modules/network"

  availability_zone_count    = var.availability_zone_count
  allowed_web_cidrs          = var.allowed_web_cidrs
  controller_bootstrap_cidrs = var.controller_bootstrap_cidrs
  enable_nat_gateways        = var.enable_nat_gateways
  enable_ssh_access          = var.enable_ssh_access
  environment                = var.environment
  flow_log_retention_days    = var.flow_log_retention_days
  ssh_allowed_cidrs          = var.ssh_allowed_cidrs
  tags                       = var.tags
  vpc_cidr                   = var.vpc_cidr
  vpc_name                   = var.vpc_name
}

module "runtime_secrets" {
  count  = var.enable_runtime_secrets ? 1 : 0
  source = "../../modules/runtime-secrets"

  aws_region              = var.aws_region
  environment             = var.environment
  project_name            = var.vpc_name
  recovery_window_in_days = var.secret_recovery_window_in_days
  tags                    = var.tags
}

module "registry" {
  source = "../../modules/ecr"

  repository_names = local.repository_names
}

module "github_oidc" {
  source = "../../modules/github-oidc"

  github_repository = var.github_repository
  github_branch     = var.github_publish_branch
  oidc_provider_arn = var.github_oidc_provider_arn
  repository_arns   = toset(values(module.registry.repository_arns))
}

module "ami_import_validation" {
  source = "../../modules/ami-import-validation"

  aws_region        = var.aws_region
  environment       = var.environment
  github_branch     = var.github_publish_branch
  github_repository = var.github_repository
  oidc_provider_arn = module.github_oidc.oidc_provider_arn
  project_name      = var.vpc_name
  tags              = var.tags
}
