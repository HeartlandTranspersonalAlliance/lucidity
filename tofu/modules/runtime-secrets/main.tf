data "aws_caller_identity" "current" {}

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

data "aws_iam_policy_document" "kms" {
  statement {
    sid       = "EnableAccountAdministration"
    effect    = "Allow"
    actions   = ["kms:*"]
    resources = ["*"]

    principals {
      type = "AWS"
      identifiers = [
        "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:root",
      ]
    }
  }
}

resource "aws_kms_key" "runtime_secrets" {
  description             = "Encrypts ${var.project_name} ${var.environment} runtime secrets"
  deletion_window_in_days = 30
  enable_key_rotation     = true
  key_usage               = "ENCRYPT_DECRYPT"
  policy                  = data.aws_iam_policy_document.kms.json

  tags = merge(local.common_tags, { Name = "${local.resource_prefix}-runtime-secrets" })
}

resource "aws_kms_alias" "runtime_secrets" {
  name          = "alias/${local.resource_prefix}-runtime-secrets"
  target_key_id = aws_kms_key.runtime_secrets.key_id
}

resource "aws_secretsmanager_secret" "controller_runtime" {
  name                    = "${var.project_name}/${var.environment}/controller-runtime"
  description             = "Runtime-only controller secrets for ${var.project_name} ${var.environment}"
  kms_key_id              = aws_kms_key.runtime_secrets.arn
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
    sid    = "DecryptControllerRuntimeSecret"
    effect = "Allow"
    actions = [
      "kms:Decrypt",
      "kms:DescribeKey",
    ]
    resources = [aws_kms_key.runtime_secrets.arn]

    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["secretsmanager.${var.aws_region}.${data.aws_partition.current.dns_suffix}"]
    }
  }
}

resource "aws_iam_policy" "controller_secrets" {
  name        = "${local.resource_prefix}-controller-secrets"
  description = "Read-only access to the ${var.project_name} ${var.environment} controller runtime secret"
  policy      = data.aws_iam_policy_document.controller_secrets.json

  tags = local.common_tags
}
