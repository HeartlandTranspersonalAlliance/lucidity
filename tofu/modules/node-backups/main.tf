data "aws_iam_policy_document" "assume_role" {
  statement {
    sid     = "AwsBackupService"
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["backup.amazonaws.com"]
    }
  }
}

data "aws_partition" "current" {}

locals {
  resource_prefix = "${var.project_name}-${var.environment}"
  common_tags = merge(
    {
      Environment = var.environment
      Project     = var.project_name
    },
    var.tags,
  )
}

resource "aws_iam_role" "backup" {
  name               = "${local.resource_prefix}-node-backup"
  assume_role_policy = data.aws_iam_policy_document.assume_role.json
  description        = "Allows AWS Backup to protect ${var.project_name} ${var.environment} EC2 nodes"

  tags = local.common_tags
}

resource "aws_iam_role_policy_attachment" "backup" {
  role       = aws_iam_role.backup.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/service-role/AWSBackupServiceRolePolicyForBackup"
}

resource "aws_iam_role" "restore" {
  name               = "${local.resource_prefix}-node-restore"
  assume_role_policy = data.aws_iam_policy_document.assume_role.json
  description        = "Allows operator-initiated AWS Backup restores of ${var.project_name} ${var.environment} EC2 nodes"

  tags = local.common_tags
}

resource "aws_iam_role_policy_attachment" "restore" {
  role       = aws_iam_role.restore.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/service-role/AWSBackupServiceRolePolicyForRestores"
}

data "aws_iam_policy_document" "restore_pass_role" {
  statement {
    sid       = "PassOnlyNodeRuntimeRolesToEc2"
    effect    = "Allow"
    actions   = ["iam:PassRole"]
    resources = values(var.instance_role_arns)

    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values   = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role_policy" "restore_pass_role" {
  name   = "pass-node-runtime-roles"
  role   = aws_iam_role.restore.id
  policy = data.aws_iam_policy_document.restore_pass_role.json
}

resource "aws_backup_vault" "nodes" {
  name        = "${local.resource_prefix}-nodes"
  kms_key_arn = var.kms_key_arn

  tags = merge(local.common_tags, {
    Name = "${local.resource_prefix}-nodes"
  })

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_backup_vault_lock_configuration" "nodes" {
  backup_vault_name  = aws_backup_vault.nodes.name
  min_retention_days = var.minimum_retention_days
  max_retention_days = var.maximum_retention_days
}

resource "aws_backup_plan" "nodes" {
  name = "${local.resource_prefix}-nodes"

  rule {
    rule_name         = "daily-node-recovery"
    target_vault_name = aws_backup_vault.nodes.name
    schedule          = var.schedule
    start_window      = var.start_window_minutes
    completion_window = var.completion_window_minutes

    lifecycle {
      delete_after = var.retention_days
    }

    recovery_point_tags = merge(local.common_tags, {
      Name       = "${local.resource_prefix}-node-recovery"
      BackupPlan = "daily-node-recovery"
    })
  }

  tags = local.common_tags
}

resource "aws_backup_selection" "nodes" {
  iam_role_arn = aws_iam_role.backup.arn
  name         = "${local.resource_prefix}-nodes"
  plan_id      = aws_backup_plan.nodes.id
  resources    = values(var.instance_arns)

  depends_on = [aws_iam_role_policy_attachment.backup]
}
