output "alarm_names" {
  description = "CloudWatch alarm names grouped by signal and node role."
  value = {
    high_cpu       = { for role, alarm in aws_cloudwatch_metric_alarm.high_cpu : role => alarm.alarm_name }
    low_cpu_credit = { for role, alarm in aws_cloudwatch_metric_alarm.low_cpu_credit : role => alarm.alarm_name }
    status_check   = { for role, alarm in aws_cloudwatch_metric_alarm.status_check : role => alarm.alarm_name }
  }
}

output "notification_topic_arn" {
  description = "Encrypted SNS topic receiving ALARM and OK transitions."
  value       = aws_sns_topic.node_alarms.arn
}

output "email_subscription_arn" {
  description = "SNS email subscription ARN or PendingConfirmation until the recipient confirms it."
  value       = aws_sns_topic_subscription.email.arn
}

output "notification_kms_key_arn" {
  description = "Customer-managed KMS key encrypting alarm notifications."
  value       = aws_kms_key.notifications.arn
}

output "settings" {
  description = "Auditable alarm thresholds and evaluation windows."
  value = {
    backup_job_failures = {
      event_rule_name = aws_cloudwatch_event_rule.backup_job_failure.name
      states          = ["ABORTED", "EXPIRED", "FAILED", "PARTIAL"]
      vault_name      = "${var.project_name}-${var.environment}-node-backups"
    }
    high_cpu = {
      datapoints_to_alarm = 3
      evaluation_periods  = 5
      period_seconds      = 300
      threshold_percent   = var.high_cpu_threshold_percent
      treat_missing_data  = "notBreaching"
    }
    low_cpu_credit = {
      datapoints_to_alarm = 2
      evaluation_periods  = 3
      period_seconds      = 300
      threshold           = var.low_cpu_credit_threshold
      treat_missing_data  = "notBreaching"
    }
    status_check = {
      datapoints_to_alarm = 2
      evaluation_periods  = 3
      period_seconds      = 60
      treat_missing_data  = "breaching"
    }
  }
}
