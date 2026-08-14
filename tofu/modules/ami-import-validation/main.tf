data "aws_caller_identity" "current" {}

data "aws_partition" "current" {}

locals {
  account_id      = data.aws_caller_identity.current.account_id
  bucket_name     = "${var.project_name}-ami-import-${local.account_id}-${var.aws_region}"
  github_subject  = "repo:${var.github_repository}:ref:refs/heads/${var.github_branch}"
  resource_prefix = "${var.project_name}-${var.environment}"
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
      "ec2:DescribeImportImageTasks",
      "ec2:DescribeSnapshots",
      "ec2:ImportImage",
    ]
    resources = ["*"]
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
}

resource "aws_iam_role_policy" "github" {
  name   = "${local.resource_prefix}-ami-validation"
  role   = aws_iam_role.github.id
  policy = data.aws_iam_policy_document.github.json
}
