output "plan_role_arn" {
  description = "GitHub Actions OIDC role for isolated test planning."
  value       = aws_iam_role.plan.arn
}

output "apply_role_arn" {
  description = "GitHub Actions OIDC role for protected saved-plan apply."
  value       = aws_iam_role.apply.arn
}

output "plan_subjects" {
  description = "Exact OIDC subjects trusted for plans."
  value       = local.plan_subjects
}

output "apply_subject" {
  description = "Exact protected-environment OIDC subject trusted for apply."
  value       = local.apply_subject
}
