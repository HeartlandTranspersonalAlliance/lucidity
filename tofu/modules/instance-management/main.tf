data "aws_partition" "current" {}
data "aws_region" "current" {}

locals {
  node_roles      = toset(["controller", "worker"])
  resource_prefix = "${var.project_name}-${var.environment}"
  common_tags = merge(
    {
      Environment = var.environment
      Project     = var.project_name
    },
    var.tags,
  )
}

data "aws_iam_policy_document" "ec2_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "node" {
  for_each = local.node_roles

  name               = "${local.resource_prefix}-${each.key}-role"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume_role.json
  description        = "Runtime identity for the ${var.project_name} ${var.environment} ${each.key} node"

  tags = merge(local.common_tags, { Role = each.key })
}

resource "aws_iam_role_policy_attachment" "ssm" {
  for_each = local.node_roles

  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonSSMManagedInstanceCore"
  role       = aws_iam_role.node[each.key].name
}

data "aws_iam_policy_document" "ecr_pull" {
  for_each = local.node_roles

  statement {
    sid       = "AuthenticateToEcr"
    effect    = "Allow"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  statement {
    sid    = "PullBootcImage"
    effect = "Allow"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:BatchGetImage",
      "ecr:GetDownloadUrlForLayer",
    ]
    resources = [var.ecr_repository_arns[each.key]]
  }
}

resource "aws_iam_role_policy" "ecr_pull" {
  for_each = local.node_roles

  name   = "${local.resource_prefix}-${each.key}-ecr-pull"
  role   = aws_iam_role.node[each.key].id
  policy = data.aws_iam_policy_document.ecr_pull[each.key].json
}

data "aws_iam_policy_document" "application_backup" {
  for_each = var.application_backup_bucket_arn == null ? toset([]) : local.node_roles

  statement {
    sid    = "ListIsolatedResticPrefix"
    effect = "Allow"
    actions = [
      "s3:GetBucketLocation",
      "s3:ListBucket",
      "s3:ListBucketVersions",
    ]
    resources = [var.application_backup_bucket_arn]

    condition {
      test     = "StringLike"
      variable = "s3:prefix"
      values = [
        "lucidity/${each.key}",
        "lucidity/${each.key}/*",
      ]
    }
  }

  statement {
    sid    = "ManageIsolatedResticObjects"
    effect = "Allow"
    actions = [
      "s3:AbortMultipartUpload",
      "s3:DeleteObject",
      "s3:GetObject",
      "s3:ListMultipartUploadParts",
      "s3:PutObject",
    ]
    resources = ["${var.application_backup_bucket_arn}/lucidity/${each.key}/*"]
  }

  dynamic "statement" {
    for_each = var.application_backup_bucket_kms_key_arn == null ? [] : [var.application_backup_bucket_kms_key_arn]
    content {
      sid    = "UseBackupBucketKey"
      effect = "Allow"
      actions = [
        "kms:Decrypt",
        "kms:Encrypt",
        "kms:GenerateDataKey",
      ]
      resources = [statement.value]
    }
  }
}

resource "aws_iam_role_policy" "application_backup" {
  for_each = data.aws_iam_policy_document.application_backup

  name   = "${local.resource_prefix}-${each.key}-application-backup"
  role   = aws_iam_role.node[each.key].id
  policy = each.value.json
}

data "aws_iam_policy_document" "application_backup_secrets" {
  for_each = {
    for role in local.node_roles : role => lookup(var.application_backup_secret_arns, role, [])
    if length(lookup(var.application_backup_secret_arns, role, [])) > 0
  }

  statement {
    sid       = "ReadExactBackupSecrets"
    effect    = "Allow"
    actions   = ["secretsmanager:DescribeSecret", "secretsmanager:GetSecretValue"]
    resources = each.value
  }

  dynamic "statement" {
    for_each = var.application_backup_secret_kms_key_arn == null ? [] : [var.application_backup_secret_kms_key_arn]
    content {
      sid       = "DecryptBackupSecrets"
      effect    = "Allow"
      actions   = ["kms:Decrypt"]
      resources = [statement.value]

      condition {
        test     = "StringEquals"
        variable = "kms:ViaService"
        values   = ["secretsmanager.${data.aws_region.current.region}.amazonaws.com"]
      }
    }
  }
}

resource "aws_iam_role_policy" "application_backup_secrets" {
  for_each = data.aws_iam_policy_document.application_backup_secrets

  name   = "${local.resource_prefix}-${each.key}-application-backup-secrets"
  role   = aws_iam_role.node[each.key].id
  policy = each.value.json
}

resource "aws_iam_role_policy_attachment" "controller_additional" {
  # The keys must be known while planning even when an ARN comes from a resource
  # created in the same apply. Keying this resource by the ARN itself makes the
  # dependency graph impossible to plan from an empty foundation.
  for_each = var.controller_policies

  policy_arn = each.value
  role       = aws_iam_role.node["controller"].name
}

resource "aws_iam_instance_profile" "node" {
  for_each = local.node_roles

  name = "${local.resource_prefix}-${each.key}-profile"
  role = aws_iam_role.node[each.key].name

  tags = merge(local.common_tags, { Role = each.key })
}
