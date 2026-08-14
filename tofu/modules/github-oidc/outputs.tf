output "oidc_provider_arn" {
  description = "GitHub Actions OIDC provider used by the publishing role."
  value       = local.oidc_provider_arn
}

output "publish_role_arn" {
  description = "IAM role ARN for GitHub Actions ECR publishing."
  value       = aws_iam_role.github_ecr_publisher.arn
}

output "trusted_subject" {
  description = "Exact GitHub OIDC subject allowed to assume the role."
  value       = local.github_oidc_subject
}
