output "github_role_arn" {
  description = "GitHub Actions role ARN for the manual AMI snapshot validation workflow."
  value       = aws_iam_role.github.arn
}

output "snapshot_kms_key_arn" {
  description = "Customer-managed KMS key ARN used by EBS Direct API snapshot uploads."
  value       = aws_kms_key.ami_snapshot.arn
}

output "github_subject" {
  description = "Exact GitHub OIDC subject allowed to run AMI snapshot validation."
  value       = local.github_subject
}
