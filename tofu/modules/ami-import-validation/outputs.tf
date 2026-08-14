output "bucket_name" {
  description = "Private S3 bucket used for disposable AMI import artifacts."
  value       = aws_s3_bucket.this.bucket
}

output "github_role_arn" {
  description = "GitHub Actions role ARN for the manual AMI import validation workflow."
  value       = aws_iam_role.github.arn
}

output "github_subject" {
  description = "Exact GitHub OIDC subject allowed to run AMI import validation."
  value       = local.github_subject
}

output "vmimport_role_name" {
  description = "VM Import Export service role name passed to ec2:ImportImage."
  value       = aws_iam_role.vmimport.name
}
