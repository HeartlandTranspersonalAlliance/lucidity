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

resource "aws_kms_key" "controller_runtime" {
  description             = "Encrypt ${var.project_name} ${var.environment} controller runtime secrets"
  enable_key_rotation     = true
  deletion_window_in_days = 30

  tags = merge(local.common_tags, { Name = "${local.resource_prefix}-controller-runtime-secrets" })
}

resource "aws_kms_alias" "controller_runtime" {
  name          = "alias/${local.resource_prefix}-controller-runtime-secrets"
  target_key_id = aws_kms_key.controller_runtime.key_id
}

resource "aws_secretsmanager_secret" "controller_runtime" {
  name                    = "${var.project_name}/${var.environment}/controller-runtime"
  description             = "Runtime-only controller secrets for ${var.project_name} ${var.environment}"
  kms_key_id              = aws_kms_key.controller_runtime.arn
  recovery_window_in_days = var.recovery_window_in_days

  tags = merge(local.common_tags, { Name = "${local.resource_prefix}-controller-runtime" })
}

data "aws_iam_policy_document" "controller_secrets" {
  statement {
    sid    = "ReadControllerRuntimeSecret"
    effect = "Allow"
    actions = [
      "secretsmanager:DescribeSecret",
      "secretsmanager:GetSecretValue",
    ]
    resources = [aws_secretsmanager_secret.controller_runtime.arn]

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["true"]
    }
  }

  statement {
    sid       = "DecryptControllerRuntimeSecret"
    effect    = "Allow"
    actions   = ["kms:Decrypt"]
    resources = [aws_kms_key.controller_runtime.arn]

    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["secretsmanager.${data.aws_region.current.region}.amazonaws.com"]
    }
  }
}

data "aws_region" "current" {}

resource "aws_iam_policy" "controller_secrets" {
  name        = "${local.resource_prefix}-controller-secrets"
  description = "Read-only access to the ${var.project_name} ${var.environment} controller runtime secret"
  policy      = data.aws_iam_policy_document.controller_secrets.json

  tags = local.common_tags
}
