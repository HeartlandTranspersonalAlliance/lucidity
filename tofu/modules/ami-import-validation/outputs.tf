output "bucket_name" {
  description = "Private S3 bucket used for disposable AMI import artifacts."
  value       = aws_s3_bucket.this.bucket
}

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

output "vmimport_role_name" {
  description = "VM Import Export service role name passed to ec2:ImportSnapshot."
  value       = aws_iam_role.vmimport.name
}
