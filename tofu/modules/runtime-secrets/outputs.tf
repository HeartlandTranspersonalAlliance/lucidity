output "controller_instance_profile_name" {
  description = "Instance profile granting the controller least-privilege runtime secret access."
  value       = aws_iam_instance_profile.controller.name
}

output "controller_role_arn" {
  description = "IAM role ARN used by the future controller EC2 instance."
  value       = aws_iam_role.controller.arn
}

output "kms_key_arn" {
  description = "KMS key ARN encrypting the controller runtime secret."
  value       = aws_kms_key.runtime_secrets.arn
}

output "secret_arn" {
  description = "ARN of the controller runtime secret container."
  value       = aws_secretsmanager_secret.controller_runtime.arn
}

output "secret_name" {
  description = "Name of the controller runtime secret container."
  value       = aws_secretsmanager_secret.controller_runtime.name
}

output "dynamic_reference_pattern" {
  description = "Runtime reference pattern for one JSON key in the controller secret."
  value       = "{{resolve:secretsmanager:${aws_secretsmanager_secret.controller_runtime.name}:SecretString:json-key}}"
}
