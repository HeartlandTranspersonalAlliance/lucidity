locals {
  repository_names = {
    controller = "${var.repository_prefix}/controller"
    worker     = "${var.repository_prefix}/worker"
  }
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
