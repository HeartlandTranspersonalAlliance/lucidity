data "aws_caller_identity" "current" {}

data "aws_partition" "current" {}

locals {
  account_id                             = data.aws_caller_identity.current.account_id
  bucket_name                            = "${var.project_name}-ami-import-${local.account_id}-${var.aws_region}"
  github_repository_parts                = split("/", var.github_repository)
  github_subject                         = "repo:${local.github_repository_parts[0]}@${var.github_repository_owner_id}/${local.github_repository_parts[1]}@${var.github_repository_id}:ref:refs/heads/${var.github_branch}"
  resource_prefix                        = "${var.project_name}-${var.environment}"
  launch_validation_instance_profile_arn = var.launch_validation_instance_profile_name == null ? null : "arn:${data.aws_partition.current.partition}:iam::${local.account_id}:instance-profile/${var.launch_validation_instance_profile_name}"
  launch_validation_subnet_arns = toset([
    for subnet_id in var.launch_validation_subnet_ids :
    "arn:${data.aws_partition.current.partition}:ec2:${var.aws_region}:${local.account_id}:subnet/${subnet_id}"
  ])
  launch_validation_security_group_arns = toset([
    for security_group_id in var.launch_validation_security_group_ids :
    "arn:${data.aws_partition.current.partition}:ec2:${var.aws_region}:${local.account_id}:security-group/${security_group_id}"
  ])
  common_tags = merge(
    {
      Environment = var.environment
      Project     = var.project_name
    },
    var.tags,
  )
}

resource "aws_s3_bucket" "this" {
  bucket = local.bucket_name

  tags = merge(local.common_tags, { Name = "${local.resource_prefix}-ami-import" })
}

resource "aws_s3_bucket_public_access_block" "this" {
  bucket = aws_s3_bucket.this.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "this" {
  bucket = aws_s3_bucket.this.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "this" {
  bucket = aws_s3_bucket.this.id

  rule {
    id     = "expire-validation-artifacts"
    status = "Enabled"

    filter {
      prefix = "validation/"
    }

    expiration {
      days = 1
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 1
    }
  }
}

data "aws_iam_policy_document" "bucket" {
  statement {
    sid     = "DenyInsecureTransport"
    effect  = "Deny"
    actions = ["s3:*"]
    resources = [
      aws_s3_bucket.this.arn,
      "${aws_s3_bucket.this.arn}/*",
    ]

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "this" {
  bucket = aws_s3_bucket.this.id
  policy = data.aws_iam_policy_document.bucket.json

  depends_on = [aws_s3_bucket_public_access_block.this]
}

data "aws_iam_policy_document" "vmimport_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["vmie.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "sts:ExternalId"
      values   = ["vmimport"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }

    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values   = ["arn:${data.aws_partition.current.partition}:vmie:*:${local.account_id}:*"]
    }
  }
}

resource "aws_iam_role" "vmimport" {
  name               = "${var.project_name}-vmimport"
  assume_role_policy = data.aws_iam_policy_document.vmimport_assume_role.json
  description        = "Allows VM Import Export to read disposable ${var.project_name} AMI artifacts"

  tags = local.common_tags
}

data "aws_iam_policy_document" "vmimport" {
  statement {
    sid    = "ReadImportBucket"
    effect = "Allow"
    actions = [
      "s3:GetBucketLocation",
      "s3:ListBucket",
    ]
    resources = [aws_s3_bucket.this.arn]
  }

  statement {
    sid       = "ReadImportArtifacts"
    effect    = "Allow"
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.this.arn}/validation/*"]
  }

  statement {
    sid    = "ImportImage"
    effect = "Allow"
    actions = [
      "ec2:CopySnapshot",
      "ec2:Describe*",
      "ec2:ModifySnapshotAttribute",
      "ec2:RegisterImage",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "vmimport" {
  name   = "${var.project_name}-vmimport"
  role   = aws_iam_role.vmimport.id
  policy = data.aws_iam_policy_document.vmimport.json
}

data "aws_iam_policy_document" "github_assume_role" {
  statement {
    sid     = "GitHubActionsAmiValidation"
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [var.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = [local.github_subject]
    }
  }
}

resource "aws_iam_role" "github" {
  name                 = "${local.resource_prefix}-github-ami-validation"
  assume_role_policy   = data.aws_iam_policy_document.github_assume_role.json
  description          = "GitHub Actions role for disposable ${var.project_name} AMI import validation"
  max_session_duration = 10800

  tags = local.common_tags

  lifecycle {
    precondition {
      condition = !var.enable_launch_validation || (
        length(var.launch_validation_subnet_ids) > 0 &&
        length(var.launch_validation_security_group_ids) > 0 &&
        var.launch_validation_instance_profile_name != null &&
        var.launch_validation_role_arn != null
      )
      error_message = "Launch validation requires at least one subnet and security group plus a worker instance profile and role."
    }
  }
}

data "aws_iam_policy_document" "github" {
  statement {
    sid    = "UseImportBucket"
    effect = "Allow"
    actions = [
      "s3:GetBucketLocation",
      "s3:ListBucket",
      "s3:ListBucketMultipartUploads",
    ]
    resources = [aws_s3_bucket.this.arn]

    condition {
      test     = "StringLike"
      variable = "s3:prefix"
      values   = ["validation/*"]
    }
  }

  statement {
    sid    = "ManageImportArtifacts"
    effect = "Allow"
    actions = [
      "s3:AbortMultipartUpload",
      "s3:DeleteObject",
      "s3:GetObject",
      "s3:ListMultipartUploadParts",
      "s3:PutObject",
    ]
    resources = ["${aws_s3_bucket.this.arn}/validation/*"]
  }

  statement {
    sid    = "ValidateAndCleanUpImport"
    effect = "Allow"
    actions = [
      "ec2:CancelImportTask",
      "ec2:DeleteSnapshot",
      "ec2:DeregisterImage",
      "ec2:DescribeImages",
      "ec2:DescribeImportSnapshotTasks",
      "ec2:DescribeInstances",
      "ec2:DescribeInstanceStatus",
      "ec2:DescribeSecurityGroups",
      "ec2:DescribeSnapshots",
      "ec2:ImportSnapshot",
      "ec2:RegisterImage",
    ]
    resources = ["*"]
  }

  dynamic "statement" {
    for_each = var.enable_launch_validation ? [1] : []

    content {
      sid     = "UseTaggedValidationImageAndSnapshot"
      effect  = "Allow"
      actions = ["ec2:RunInstances"]
      resources = [
        "arn:${data.aws_partition.current.partition}:ec2:${var.aws_region}:${local.account_id}:image/*",
        "arn:${data.aws_partition.current.partition}:ec2:${var.aws_region}:${local.account_id}:snapshot/*",
      ]

      condition {
        test     = "StringEquals"
        variable = "ec2:ResourceTag/Purpose"
        values   = ["ami-validation"]
      }
    }
  }

  dynamic "statement" {
    for_each = var.enable_launch_validation ? [1] : []

    content {
      sid     = "UseValidationNetwork"
      effect  = "Allow"
      actions = ["ec2:RunInstances"]
      resources = concat(
        tolist(local.launch_validation_subnet_arns),
        tolist(local.launch_validation_security_group_arns),
      )
    }
  }

  dynamic "statement" {
    for_each = var.enable_launch_validation ? [1] : []

    content {
      sid     = "CreateTaggedValidationInstance"
      effect  = "Allow"
      actions = ["ec2:RunInstances"]
      resources = [
        "arn:${data.aws_partition.current.partition}:ec2:${var.aws_region}:${local.account_id}:instance/*",
      ]

      condition {
        test     = "StringEquals"
        variable = "aws:RequestTag/Purpose"
        values   = ["ami-validation"]
      }

      condition {
        test     = "StringEquals"
        variable = "ec2:InstanceType"
        values   = [var.launch_validation_instance_type]
      }

      condition {
        test     = "StringEquals"
        variable = "ec2:InstanceProfile"
        values   = [local.launch_validation_instance_profile_arn]
      }

      condition {
        test     = "StringEquals"
        variable = "ec2:MetadataHttpEndpoint"
        values   = ["enabled"]
      }

      condition {
        test     = "StringEquals"
        variable = "ec2:MetadataHttpTokens"
        values   = ["required"]
      }

      condition {
        test     = "NumericEquals"
        variable = "ec2:MetadataHttpPutResponseHopLimit"
        values   = ["2"]
      }
    }
  }

  dynamic "statement" {
    for_each = var.enable_launch_validation ? [1] : []

    content {
      sid     = "CreateTaggedValidationStorageAndNetworkInterface"
      effect  = "Allow"
      actions = ["ec2:RunInstances"]
      resources = [
        "arn:${data.aws_partition.current.partition}:ec2:${var.aws_region}:${local.account_id}:network-interface/*",
        "arn:${data.aws_partition.current.partition}:ec2:${var.aws_region}:${local.account_id}:volume/*",
      ]

      condition {
        test     = "StringEquals"
        variable = "aws:RequestTag/Purpose"
        values   = ["ami-validation"]
      }
    }
  }

  dynamic "statement" {
    for_each = var.enable_launch_validation ? [1] : []

    content {
      sid    = "TagValidationArtifacts"
      effect = "Allow"
      actions = [
        "ec2:CreateTags",
      ]
      resources = [
        "arn:${data.aws_partition.current.partition}:ec2:${var.aws_region}:${local.account_id}:image/*",
        "arn:${data.aws_partition.current.partition}:ec2:${var.aws_region}:${local.account_id}:instance/*",
        "arn:${data.aws_partition.current.partition}:ec2:${var.aws_region}:${local.account_id}:network-interface/*",
        "arn:${data.aws_partition.current.partition}:ec2:${var.aws_region}:${local.account_id}:snapshot/*",
        "arn:${data.aws_partition.current.partition}:ec2:${var.aws_region}:${local.account_id}:volume/*",
      ]
    }
  }

  dynamic "statement" {
    for_each = var.enable_launch_validation ? [1] : []

    content {
      sid       = "TerminateTaggedValidationInstance"
      effect    = "Allow"
      actions   = ["ec2:TerminateInstances"]
      resources = ["arn:${data.aws_partition.current.partition}:ec2:${var.aws_region}:${local.account_id}:instance/*"]

      condition {
        test     = "StringEquals"
        variable = "ec2:ResourceTag/Purpose"
        values   = ["ami-validation"]
      }
    }
  }

  dynamic "statement" {
    for_each = var.enable_launch_validation ? [1] : []

    content {
      sid    = "ValidateGuestWithSsm"
      effect = "Allow"
      actions = [
        "ssm:GetCommandInvocation",
        "ssm:DescribeInstanceInformation",
      ]
      resources = ["*"]
    }
  }

  dynamic "statement" {
    for_each = var.enable_launch_validation ? [1] : []

    content {
      sid     = "RunApprovedSsmDocument"
      effect  = "Allow"
      actions = ["ssm:SendCommand"]
      resources = [
        "arn:${data.aws_partition.current.partition}:ssm:${var.aws_region}::document/AWS-RunShellScript",
      ]
    }
  }

  dynamic "statement" {
    for_each = var.enable_launch_validation ? [1] : []

    content {
      sid     = "RunCommandOnTaggedValidationInstance"
      effect  = "Allow"
      actions = ["ssm:SendCommand"]
      resources = [
        "arn:${data.aws_partition.current.partition}:ec2:${var.aws_region}:${local.account_id}:instance/*",
      ]

      condition {
        test     = "StringEquals"
        variable = "ssm:resourceTag/Purpose"
        values   = ["ami-validation"]
      }
    }
  }

  statement {
    sid       = "PassVmImportRole"
    effect    = "Allow"
    actions   = ["iam:PassRole"]
    resources = [aws_iam_role.vmimport.arn]

    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values   = ["vmie.amazonaws.com"]
    }
  }

  dynamic "statement" {
    for_each = var.enable_launch_validation ? [1] : []

    content {
      sid       = "PassValidationInstanceRole"
      effect    = "Allow"
      actions   = ["iam:PassRole"]
      resources = [var.launch_validation_role_arn]

      condition {
        test     = "StringEquals"
        variable = "iam:PassedToService"
        values   = ["ec2.amazonaws.com"]
      }
    }
  }
}

resource "aws_iam_role_policy" "github" {
  name   = "${local.resource_prefix}-ami-validation"
  role   = aws_iam_role.github.id
  policy = data.aws_iam_policy_document.github.json
}
