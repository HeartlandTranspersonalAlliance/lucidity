output "ecr_repository_arns" {
  description = "ECR repository ARNs keyed by bootc image role."
  value       = module.registry.repository_arns
}

output "ecr_repository_names" {
  description = "ECR repository names keyed by bootc image role."
  value       = module.registry.repository_names
}

output "ecr_repository_urls" {
  description = "ECR repository URLs keyed by bootc image role."
  value       = module.registry.repository_urls
}

output "github_oidc_provider_arn" {
  description = "GitHub Actions OIDC provider used by the publishing role."
  value       = module.github_oidc.oidc_provider_arn
}

output "github_oidc_subject" {
  description = "Exact GitHub OIDC subject permitted to publish images."
  value       = module.github_oidc.trusted_subject
}

output "github_publish_role_arn" {
  description = "IAM role ARN to configure in the GitHub publishing workflow."
  value       = module.github_oidc.publish_role_arn
}
