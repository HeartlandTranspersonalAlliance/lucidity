output "vault_arn" {
  description = "ARN of the governance-locked node backup vault."
  value       = aws_backup_vault.nodes.arn
}

output "vault_name" {
  description = "Name of the governance-locked node backup vault."
  value       = aws_backup_vault.nodes.name
}

output "plan_id" {
  description = "AWS Backup plan protecting the controller and worker."
  value       = aws_backup_plan.nodes.id
}

output "service_role_arn" {
  description = "Backup-only IAM service role used by the plan selection."
  value       = aws_iam_role.backup.arn
}

output "restore_role_arn" {
  description = "Dedicated AWS Backup restore role with PassRole restricted to the two node runtime roles."
  value       = aws_iam_role.restore.arn
}

output "retention_days" {
  description = "Configured daily backup retention."
  value       = var.retention_days
}

output "settings" {
  description = "Auditable backup schedule, retention controls, and selected node roles."
  value = {
    completion_window_minutes = var.completion_window_minutes
    maximum_retention_days    = var.maximum_retention_days
    minimum_retention_days    = var.minimum_retention_days
    protected_roles           = sort(keys(var.instance_arns))
    retention_days            = var.retention_days
    schedule                  = var.schedule
    start_window_minutes      = var.start_window_minutes
    vault_lock_mode           = "governance"
  }
}
