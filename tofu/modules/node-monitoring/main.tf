data "aws_caller_identity" "current" {}

data "aws_partition" "current" {}

locals {
  account_id      = data.aws_caller_identity.current.account_id
  resource_prefix = "${var.project_name}-${var.environment}"
  alarm_arn       = "arn:${data.aws_partition.current.partition}:cloudwatch:${var.aws_region}:${local.account_id}:alarm:${local.resource_prefix}-*"
  topic_arn       = "arn:${data.aws_partition.current.partition}:sns:${var.aws_region}:${local.account_id}:${local.resource_prefix}-node-alarms"
  backup_rule_arn = "arn:${data.aws_partition.current.partition}:events:${var.aws_region}:${local.account_id}:rule/${local.resource_prefix}-backup-job-failures"
  common_tags = merge(
    {
      Environment = var.environment
      Project     = var.project_name
    },
    var.tags,
  )
}

data "aws_iam_policy_document" "notifications_kms" {
  statement {
    sid       = "EnableAccountAdministration"
    effect    = "Allow"
    actions   = ["kms:*"]
    resources = ["*"]

    principals {
      type        = "AWS"
      identifiers = ["arn:${data.aws_partition.current.partition}:iam::${local.account_id}:root"]
    }
  }

  statement {
    sid    = "AllowSnsTopicEncryption"
    effect = "Allow"
    actions = [
      "kms:Decrypt",
      "kms:GenerateDataKey*",
    ]
    resources = ["*"]

    principals {
      type        = "Service"
      identifiers = ["sns.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "kms:EncryptionContext:aws:sns:topicArn"
      values   = [local.topic_arn]
    }
  }

  statement {
    sid    = "AllowCloudWatchAlarmEncryption"
    effect = "Allow"
    actions = [
      "kms:Decrypt",
      "kms:GenerateDataKey*",
    ]
    resources = ["*"]

    principals {
      type        = "Service"
      identifiers = ["cloudwatch.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "kms:EncryptionContext:aws:sns:topicArn"
      values   = [local.topic_arn]
    }
  }

  statement {
    sid    = "AllowEventBridgeNotificationEncryption"
    effect = "Allow"
    actions = [
      "kms:Decrypt",
      "kms:GenerateDataKey*",
    ]
    resources = ["*"]

    principals {
      type        = "Service"
      identifiers = ["events.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "kms:EncryptionContext:aws:sns:topicArn"
      values   = [local.topic_arn]
    }
  }
}

resource "aws_kms_key" "notifications" {
  description             = "Encrypts ${var.project_name} ${var.environment} node alarm notifications"
  deletion_window_in_days = 30
  enable_key_rotation     = true
  key_usage               = "ENCRYPT_DECRYPT"
  policy                  = data.aws_iam_policy_document.notifications_kms.json

  tags = merge(local.common_tags, { Name = "${local.resource_prefix}-node-alarms" })
}

resource "aws_kms_alias" "notifications" {
  name          = "alias/${local.resource_prefix}-node-alarms"
  target_key_id = aws_kms_key.notifications.key_id
}

resource "aws_sns_topic" "node_alarms" {
  name              = "${local.resource_prefix}-node-alarms"
  kms_master_key_id = aws_kms_key.notifications.arn

  tags = merge(local.common_tags, { Name = "${local.resource_prefix}-node-alarms" })

  lifecycle {
    postcondition {
      condition     = self.arn == local.topic_arn
      error_message = "The encrypted alarm topic ARN must match its scoped KMS encryption context."
    }
  }
}

data "aws_iam_policy_document" "node_alarms" {
  statement {
    sid    = "AccountTopicAdministration"
    effect = "Allow"
    actions = [
      "sns:AddPermission",
      "sns:DeleteTopic",
      "sns:GetTopicAttributes",
      "sns:ListSubscriptionsByTopic",
      "sns:Publish",
      "sns:Receive",
      "sns:RemovePermission",
      "sns:SetTopicAttributes",
      "sns:Subscribe",
    ]
    resources = [aws_sns_topic.node_alarms.arn]

    principals {
      type        = "AWS"
      identifiers = ["arn:${data.aws_partition.current.partition}:iam::${local.account_id}:root"]
    }
  }

  statement {
    sid       = "CloudWatchAlarmPublish"
    effect    = "Allow"
    actions   = ["sns:Publish"]
    resources = [aws_sns_topic.node_alarms.arn]

    principals {
      type        = "Service"
      identifiers = ["cloudwatch.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }

    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values   = [local.alarm_arn]
    }
  }

  statement {
    sid       = "EventBridgeBackupFailurePublish"
    effect    = "Allow"
    actions   = ["sns:Publish"]
    resources = [aws_sns_topic.node_alarms.arn]

    principals {
      type        = "Service"
      identifiers = ["events.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }

    condition {
      test     = "ArnEquals"
      variable = "aws:SourceArn"
      values   = [local.backup_rule_arn]
    }
  }
}

resource "aws_sns_topic_policy" "node_alarms" {
  arn    = aws_sns_topic.node_alarms.arn
  policy = data.aws_iam_policy_document.node_alarms.json
}

resource "aws_sns_topic_subscription" "email" {
  topic_arn = aws_sns_topic.node_alarms.arn
  protocol  = "email"
  endpoint  = var.notification_email
}

resource "aws_cloudwatch_event_rule" "backup_job_failure" {
  name        = "${local.resource_prefix}-backup-job-failures"
  description = "Notify operators when the Lucidity node backup job fails, aborts, expires, or completes partially"
  event_pattern = jsonencode({
    source        = ["aws.backup"]
    "detail-type" = ["Backup Job State Change"]
    detail = {
      backupVaultName = ["${local.resource_prefix}-node-backups"]
      state           = ["ABORTED", "EXPIRED", "FAILED", "PARTIAL"]
    }
  })

  tags = merge(local.common_tags, { Name = "${local.resource_prefix}-backup-job-failures" })

  lifecycle {
    postcondition {
      condition     = self.arn == local.backup_rule_arn
      error_message = "The backup failure rule ARN must match the SNS and KMS source restriction."
    }
  }
}

resource "aws_cloudwatch_event_target" "backup_job_failure" {
  rule      = aws_cloudwatch_event_rule.backup_job_failure.name
  target_id = "encrypted-operator-notification"
  arn       = aws_sns_topic.node_alarms.arn

  depends_on = [aws_sns_topic_policy.node_alarms]
}

resource "aws_cloudwatch_metric_alarm" "status_check" {
  for_each = var.instance_ids

  alarm_name          = "${local.resource_prefix}-${each.key}-status-check"
  alarm_description   = "${title(each.key)} EC2 instance or system status check failed"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 3
  datapoints_to_alarm = 2
  metric_name         = "StatusCheckFailed"
  namespace           = "AWS/EC2"
  period              = 60
  statistic           = "Maximum"
  threshold           = 1
  treat_missing_data  = "breaching"
  actions_enabled     = true

  dimensions = {
    InstanceId = each.value
  }

  alarm_actions             = [aws_sns_topic.node_alarms.arn]
  insufficient_data_actions = []
  ok_actions                = [aws_sns_topic.node_alarms.arn]
  tags                      = merge(local.common_tags, { Role = each.key })
}

resource "aws_cloudwatch_metric_alarm" "high_cpu" {
  for_each = var.instance_ids

  alarm_name          = "${local.resource_prefix}-${each.key}-high-cpu"
  alarm_description   = "${title(each.key)} EC2 CPU utilization remained above ${var.high_cpu_threshold_percent} percent"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 5
  datapoints_to_alarm = 3
  metric_name         = "CPUUtilization"
  namespace           = "AWS/EC2"
  period              = 300
  statistic           = "Average"
  threshold           = var.high_cpu_threshold_percent
  treat_missing_data  = "notBreaching"
  actions_enabled     = true

  dimensions = {
    InstanceId = each.value
  }

  alarm_actions             = [aws_sns_topic.node_alarms.arn]
  insufficient_data_actions = []
  ok_actions                = [aws_sns_topic.node_alarms.arn]
  tags                      = merge(local.common_tags, { Role = each.key })
}

resource "aws_cloudwatch_metric_alarm" "low_cpu_credit" {
  for_each = var.instance_ids

  alarm_name          = "${local.resource_prefix}-${each.key}-low-cpu-credit"
  alarm_description   = "${title(each.key)} burstable EC2 CPU credit balance is low"
  comparison_operator = "LessThanOrEqualToThreshold"
  evaluation_periods  = 3
  datapoints_to_alarm = 2
  metric_name         = "CPUCreditBalance"
  namespace           = "AWS/EC2"
  period              = 300
  statistic           = "Minimum"
  threshold           = var.low_cpu_credit_threshold
  treat_missing_data  = "notBreaching"
  actions_enabled     = true

  dimensions = {
    InstanceId = each.value
  }

  alarm_actions             = [aws_sns_topic.node_alarms.arn]
  insufficient_data_actions = []
  ok_actions                = [aws_sns_topic.node_alarms.arn]
  tags                      = merge(local.common_tags, { Role = each.key })
}
