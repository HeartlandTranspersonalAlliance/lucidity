output "controller_policy_arn" {
  description = "Customer-managed policy granting read-only access to the controller runtime secret."
  value       = aws_iam_policy.controller_secrets.arn
}

output "kms_key_id" {
  description = "Customer-managed KMS key ARN encrypting the controller runtime secret."
  value       = aws_kms_key.controller_runtime.arn
}

output "secret_arn" {
  description = "ARN of the controller runtime secret container."
  value       = aws_secretsmanager_secret.controller_runtime.arn
}

output "secret_name" {
  description = "Name of the controller runtime secret container."
  value       = aws_secretsmanager_secret.controller_runtime.name
}

output "kms_key_arn" {
  description = "KMS key ARN encrypting the controller runtime secret."
  value       = aws_kms_key.controller_runtime.arn
}

output "dynamic_reference_pattern" {
  description = "Runtime reference pattern for one JSON key in the controller secret."
  value       = "{{resolve:secretsmanager:${aws_secretsmanager_secret.controller_runtime.name}:SecretString:json-key}}"
}
