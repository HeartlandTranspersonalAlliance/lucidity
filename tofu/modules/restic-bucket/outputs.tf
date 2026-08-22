output "bucket_arn" {
  value       = aws_s3_bucket.restic.arn
  description = "ARN of the isolated Restic bucket."
}

output "kms_key_arn" {
  value       = aws_kms_key.restic.arn
  description = "KMS key encrypting the isolated Restic bucket."
}
