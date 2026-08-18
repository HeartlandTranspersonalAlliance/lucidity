output "instance_profile_names" {
  description = "SSM-enabled EC2 instance profile names keyed by node role."
  value       = { for role, profile in aws_iam_instance_profile.node : role => profile.name }
}

output "role_arns" {
  description = "EC2 IAM role ARNs keyed by node role."
  value       = { for role, node_role in aws_iam_role.node : role => node_role.arn }
}

output "application_backup_access" {
  description = "Auditable role-to-prefix and exact-secret access configured for application backups."
  value = {
    bucket_arn = var.application_backup_bucket_arn
    object_prefixes = var.application_backup_bucket_arn == null ? {} : {
      for role in ["controller", "worker"] : role => "${var.application_backup_bucket_arn}/lucidity/${role}/*"
    }
    secret_arns = var.application_backup_secret_arns
  }
}
