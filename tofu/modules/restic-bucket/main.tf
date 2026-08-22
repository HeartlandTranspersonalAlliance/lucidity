data "aws_caller_identity" "current" {}

locals {
  name = "${var.project_name}-${var.environment}-restic-${data.aws_caller_identity.current.account_id}-${var.aws_region}"
  tags = merge({ Environment = var.environment, Project = var.project_name }, var.tags)
}

resource "aws_kms_key" "restic" {
  description             = "Encrypt ${var.project_name} ${var.environment} Restic backups"
  enable_key_rotation     = true
  deletion_window_in_days = 30
  tags                    = merge(local.tags, { Name = "${var.project_name}-${var.environment}-restic" })
}

resource "aws_kms_alias" "restic" {
  name          = "alias/${var.project_name}-${var.environment}-restic"
  target_key_id = aws_kms_key.restic.key_id
}

resource "aws_s3_bucket" "restic" {
  bucket        = local.name
  force_destroy = false
  tags          = merge(local.tags, { Name = local.name, Purpose = "Restic application backups" })

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_versioning" "restic" {
  bucket = aws_s3_bucket.restic.id
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "restic" {
  bucket = aws_s3_bucket.restic.id
  rule {
    bucket_key_enabled = true
    apply_server_side_encryption_by_default {
      kms_master_key_id = aws_kms_key.restic.arn
      sse_algorithm     = "aws:kms"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "restic" {
  bucket                  = aws_s3_bucket.restic.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}
