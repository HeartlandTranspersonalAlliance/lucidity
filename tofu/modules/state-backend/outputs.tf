output "state_bucket_name" {
  description = "Account-regional S3 bucket that stores OpenTofu state and native lock objects."
  value       = aws_s3_bucket.state.bucket
}

output "access_log_bucket_name" {
  description = "Account-regional S3 bucket receiving state-bucket server access logs."
  value       = aws_s3_bucket.access_logs.bucket
}

output "backend_configuration" {
  description = "Non-secret partial S3 backend settings for the main AWS environment."
  value = {
    bucket       = aws_s3_bucket.state.bucket
    encrypt      = true
    key          = "${var.project_name}/${var.environment}/terraform.tfstate"
    region       = var.aws_region
    use_lockfile = true
  }
}

output "security_controls" {
  description = "Auditable state and access-log bucket security controls."
  value = {
    access_log_abac          = aws_s3_bucket_abac.access_logs.abac_status[0].status
    access_log_versioning    = aws_s3_bucket_versioning.access_logs.versioning_configuration[0].status
    blocked_encryption_types = one(aws_s3_bucket_server_side_encryption_configuration.state.rule).blocked_encryption_types
    default_encryption       = one(aws_s3_bucket_server_side_encryption_configuration.state.rule).apply_server_side_encryption_by_default[0].sse_algorithm
    state_abac               = aws_s3_bucket_abac.state.abac_status[0].status
    state_access_log_prefix  = aws_s3_bucket_logging.state.target_prefix
    state_access_log_target  = aws_s3_bucket_logging.state.target_bucket
    state_bucket_namespace   = aws_s3_bucket.state.bucket_namespace
    state_force_destroy      = aws_s3_bucket.state.force_destroy
    state_versioning         = aws_s3_bucket_versioning.state.versioning_configuration[0].status
    access_log_namespace     = aws_s3_bucket.access_logs.bucket_namespace
    access_log_force_destroy = aws_s3_bucket.access_logs.force_destroy
  }
}

output "backend_access_policy_json" {
  description = "Least-privilege IAM policy document to attach to authorized OpenTofu operator roles."
  value       = data.aws_iam_policy_document.backend_access.json
}
