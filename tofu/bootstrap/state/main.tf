data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

locals {
  resource_prefix = "${var.project_name}-${var.environment}"
  state_bucket_name = join("-", [
    local.resource_prefix,
    "tofu-state",
    data.aws_caller_identity.current.account_id,
    var.aws_region,
    "an",
  ])
  access_log_bucket_name = join("-", [
    local.resource_prefix,
    "tofu-logs",
    data.aws_caller_identity.current.account_id,
    var.aws_region,
    "an",
  ])
  common_tags = merge(
    {
      Environment = var.environment
      Project     = var.project_name
    },
    var.tags,
  )
}

resource "aws_s3_bucket" "state" {
  bucket           = local.state_bucket_name
  bucket_namespace = "account-regional"
  force_destroy    = false

  tags = merge(local.common_tags, {
    Name    = local.state_bucket_name
    Purpose = "OpenTofu remote state"
  })

  lifecycle {
    prevent_destroy = true

    precondition {
      condition     = length(local.state_bucket_name) <= 63
      error_message = "The project, environment, account, and region produce a state bucket name longer than 63 characters."
    }
  }
}

resource "aws_s3_bucket" "access_logs" {
  bucket           = local.access_log_bucket_name
  bucket_namespace = "account-regional"
  force_destroy    = false

  tags = merge(local.common_tags, {
    Name    = local.access_log_bucket_name
    Purpose = "OpenTofu state access logs"
  })

  lifecycle {
    prevent_destroy = true

    precondition {
      condition     = length(local.access_log_bucket_name) <= 63
      error_message = "The project, environment, account, and region produce an access-log bucket name longer than 63 characters."
    }
  }
}

resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.state.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_versioning" "access_logs" {
  bucket = aws_s3_bucket.access_logs.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  bucket = aws_s3_bucket.state.id

  rule {
    blocked_encryption_types = ["SSE-C"]
    bucket_key_enabled       = true

    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "access_logs" {
  bucket = aws_s3_bucket.access_logs.id

  rule {
    blocked_encryption_types = ["SSE-C"]
    bucket_key_enabled       = true

    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_abac" "state" {
  bucket = aws_s3_bucket.state.id

  abac_status {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_abac" "access_logs" {
  bucket = aws_s3_bucket.access_logs.id

  abac_status {
    status = "Enabled"
  }
}

data "aws_iam_policy_document" "state" {
  statement {
    sid     = "DenyInsecureTransport"
    effect  = "Deny"
    actions = ["s3:*"]
    resources = [
      aws_s3_bucket.state.arn,
      "${aws_s3_bucket.state.arn}/*",
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

data "aws_iam_policy_document" "access_logs" {
  statement {
    sid     = "S3ServerAccessLogDelivery"
    effect  = "Allow"
    actions = ["s3:PutObject"]
    resources = [
      "${aws_s3_bucket.access_logs.arn}/state-bucket/*",
    ]

    principals {
      type        = "Service"
      identifiers = ["logging.s3.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }

    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values   = [aws_s3_bucket.state.arn]
    }
  }

  statement {
    sid     = "DenyInsecureTransport"
    effect  = "Deny"
    actions = ["s3:*"]
    resources = [
      aws_s3_bucket.access_logs.arn,
      "${aws_s3_bucket.access_logs.arn}/*",
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

data "aws_iam_policy_document" "backend_access" {
  statement {
    sid       = "ReadStateBucketConfiguration"
    actions   = ["s3:GetBucketVersioning"]
    resources = [aws_s3_bucket.state.arn]
  }

  statement {
    sid = "ListStateObjects"
    actions = [
      "s3:ListBucket",
      "s3:ListBucketVersions",
    ]
    resources = [aws_s3_bucket.state.arn]

    condition {
      test     = "StringLike"
      variable = "s3:prefix"
      values = [
        "${var.project_name}/${var.environment}/terraform.tfstate",
        "${var.project_name}/${var.environment}/terraform.tfstate.tflock",
        "${var.project_name}/${var.environment}/bootstrap.tfstate",
        "${var.project_name}/${var.environment}/bootstrap.tfstate.tflock",
      ]
    }
  }

  statement {
    sid = "ManageStateAndLockObjects"
    actions = [
      "s3:DeleteObject",
      "s3:GetObject",
      "s3:GetObjectTagging",
      "s3:GetObjectVersion",
      "s3:PutObject",
      "s3:PutObjectTagging",
    ]
    resources = [
      "${aws_s3_bucket.state.arn}/${var.project_name}/${var.environment}/terraform.tfstate",
      "${aws_s3_bucket.state.arn}/${var.project_name}/${var.environment}/terraform.tfstate.tflock",
      "${aws_s3_bucket.state.arn}/${var.project_name}/${var.environment}/bootstrap.tfstate",
      "${aws_s3_bucket.state.arn}/${var.project_name}/${var.environment}/bootstrap.tfstate.tflock",
    ]
  }
}

resource "aws_s3_bucket_policy" "state" {
  bucket = aws_s3_bucket.state.id
  policy = data.aws_iam_policy_document.state.json
}

resource "aws_s3_bucket_policy" "access_logs" {
  bucket = aws_s3_bucket.access_logs.id
  policy = data.aws_iam_policy_document.access_logs.json
}

resource "aws_s3_bucket_logging" "state" {
  bucket        = aws_s3_bucket.state.id
  target_bucket = aws_s3_bucket.access_logs.bucket
  target_prefix = "state-bucket/"

  target_object_key_format {
    partitioned_prefix {
      partition_date_source = "EventTime"
    }
  }

  depends_on = [aws_s3_bucket_policy.access_logs]
}

resource "aws_s3_bucket_lifecycle_configuration" "state" {
  bucket = aws_s3_bucket.state.id

  rule {
    id     = "retain-recoverable-state-versions"
    status = "Enabled"

    filter {
      tag {
        key   = "object:type"
        value = "state"
      }
    }

    noncurrent_version_expiration {
      newer_noncurrent_versions = 100
      noncurrent_days           = 365
    }
  }

  rule {
    id     = "expire-lock-versions"
    status = "Enabled"

    filter {
      tag {
        key   = "object:type"
        value = "lock"
      }
    }

    noncurrent_version_expiration {
      newer_noncurrent_versions = 10
      noncurrent_days           = 30
    }
  }

  rule {
    id     = "abort-incomplete-uploads"
    status = "Enabled"

    filter {}

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }

  rule {
    id     = "remove-expired-delete-markers"
    status = "Enabled"

    filter {}

    expiration {
      expired_object_delete_marker = true
    }
  }

  depends_on = [aws_s3_bucket_versioning.state]
}

resource "aws_s3_bucket_lifecycle_configuration" "access_logs" {
  bucket = aws_s3_bucket.access_logs.id

  rule {
    id     = "expire-access-logs"
    status = "Enabled"

    filter {}

    expiration {
      days = var.access_log_retention_days
    }

    noncurrent_version_expiration {
      noncurrent_days = 30
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }

  rule {
    id     = "remove-expired-delete-markers"
    status = "Enabled"

    filter {}

    expiration {
      expired_object_delete_marker = true
    }
  }

  depends_on = [aws_s3_bucket_versioning.access_logs]
}
