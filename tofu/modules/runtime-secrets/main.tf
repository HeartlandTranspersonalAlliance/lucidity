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

resource "aws_secretsmanager_secret" "controller_runtime" {
  name                    = "${var.project_name}/${var.environment}/controller-runtime"
  description             = "Runtime-only controller secrets for ${var.project_name} ${var.environment}"
  kms_key_id              = "alias/aws/secretsmanager"
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
}

resource "aws_iam_policy" "controller_secrets" {
  name        = "${local.resource_prefix}-controller-secrets"
  description = "Read-only access to the ${var.project_name} ${var.environment} controller runtime secret"
  policy      = data.aws_iam_policy_document.controller_secrets.json

  tags = local.common_tags
}
