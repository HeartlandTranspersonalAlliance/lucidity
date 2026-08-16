output "github_role_arn" {
  description = "GitHub Actions role ARN for production deployment enrollment and validation."
  value       = aws_iam_role.github.arn
}

output "github_subject" {
  description = "Exact GitHub OIDC subject allowed to validate the production deployment."
  value       = local.github_subject
}
