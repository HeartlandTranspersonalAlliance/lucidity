data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

locals {
  account_id      = data.aws_caller_identity.current.account_id
  repository      = split("/", var.github_repository)
  repository_slug = "${local.repository[0]}@${var.github_repository_owner_id}/${local.repository[1]}@${var.github_repository_id}"
  plan_subjects = [
    "repo:${local.repository_slug}:ref:refs/heads/${var.github_branch}",
    "repo:${local.repository_slug}:pull_request",
  ]
  apply_subject     = "repo:${local.repository_slug}:environment:${var.github_environment}"
  state_bucket_arn  = "arn:${data.aws_partition.current.partition}:s3:::${var.state_bucket_name}"
  restic_bucket_arn = "arn:${data.aws_partition.current.partition}:s3:::${var.project_name}-${var.environment}-restic-${local.account_id}-${var.aws_region}"
  state_object_arns = [
    "${local.state_bucket_arn}/${var.state_key}",
    "${local.state_bucket_arn}/${var.state_key}.tflock",
  ]
  plan_read_actions = [
    "backup:Describe*", "backup:Get*", "backup:List*",
    "cloudwatch:Describe*", "cloudwatch:Get*", "cloudwatch:List*",
    "ec2:Describe*",
    "iam:Get*", "iam:List*",
    "kms:DescribeKey", "kms:GetKeyPolicy", "kms:GetKeyRotationStatus", "kms:ListAliases", "kms:ListResourceTags",
    "logs:Describe*", "logs:Get*", "logs:List*",
    "secretsmanager:DescribeSecret", "secretsmanager:ListSecrets", "secretsmanager:ListSecretVersionIds",
    "ssm:Describe*", "ssm:Get*", "ssm:List*",
    "sts:GetCallerIdentity",
    "tag:GetResources",
  ]
  common_tags = merge({
    Environment = var.environment
    Project     = var.project_name
  }, var.tags)
}

data "aws_iam_policy_document" "plan_trust" {
  statement {
    sid     = "GitHubActionsReviewedPlan"
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
      values   = local.plan_subjects
    }
  }
}

data "aws_iam_policy_document" "apply_trust" {
  statement {
    sid     = "GitHubActionsProtectedApply"
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
      values   = [local.apply_subject]
    }
  }
}

resource "aws_iam_role" "plan" {
  name                 = "${var.project_name}-${var.environment}-github-infra-plan"
  description          = "Read-only planning and exact state access for ${var.project_name} ${var.environment}"
  assume_role_policy   = data.aws_iam_policy_document.plan_trust.json
  max_session_duration = 3600
  tags                 = local.common_tags
}

resource "aws_iam_role" "apply" {
  name                 = "${var.project_name}-${var.environment}-github-infra-apply"
  description          = "Protected saved-plan apply for ${var.project_name} ${var.environment}"
  assume_role_policy   = data.aws_iam_policy_document.apply_trust.json
  max_session_duration = 3600
  tags                 = local.common_tags
}

data "aws_iam_policy_document" "state" {
  statement {
    sid       = "ListExactState"
    effect    = "Allow"
    actions   = ["s3:GetBucketVersioning", "s3:ListBucket"]
    resources = [local.state_bucket_arn]

    condition {
      test     = "StringLike"
      variable = "s3:prefix"
      values   = [var.state_key, "${var.state_key}.tflock"]
    }
  }

  statement {
    sid       = "ManageExactState"
    effect    = "Allow"
    actions   = ["s3:DeleteObject", "s3:GetObject", "s3:GetObjectTagging", "s3:GetObjectVersion", "s3:PutObject", "s3:PutObjectTagging"]
    resources = local.state_object_arns
  }
}

resource "aws_iam_role_policy" "plan_state" {
  name   = "exact-${var.environment}-state"
  role   = aws_iam_role.plan.id
  policy = data.aws_iam_policy_document.state.json
}

resource "aws_iam_role_policy" "apply_state" {
  name   = "exact-${var.environment}-state"
  role   = aws_iam_role.apply.id
  policy = data.aws_iam_policy_document.state.json
}

data "aws_iam_policy_document" "restic_read" {
  statement {
    sid       = "ListBucketsForProviderRefresh"
    effect    = "Allow"
    actions   = ["s3:ListAllMyBuckets"]
    resources = ["*"]
  }

  statement {
    sid    = "ReadIsolatedResticBucket"
    effect = "Allow"
    actions = [
      "s3:GetBucketLocation", "s3:GetBucketPolicy", "s3:GetBucketPublicAccessBlock",
      "s3:GetBucketTagging", "s3:GetBucketVersioning", "s3:GetEncryptionConfiguration",
      "s3:ListBucket", "s3:ListBucketVersions",
    ]
    resources = [local.restic_bucket_arn]
  }
}

resource "aws_iam_role_policy" "plan_restic_read" {
  name   = "read-${var.environment}-restic-bucket"
  role   = aws_iam_role.plan.id
  policy = data.aws_iam_policy_document.restic_read.json
}

resource "aws_iam_role_policy" "apply_restic_read" {
  name   = "read-${var.environment}-restic-bucket"
  role   = aws_iam_role.apply.id
  policy = data.aws_iam_policy_document.restic_read.json
}

data "aws_iam_policy_document" "plan_read" {
  statement {
    sid       = "ReadDeploymentConfiguration"
    effect    = "Allow"
    actions   = local.plan_read_actions
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "plan_read" {
  name   = "read-${var.environment}-deployment"
  role   = aws_iam_role.plan.id
  policy = data.aws_iam_policy_document.plan_read.json
}

data "aws_iam_policy_document" "apply" {
  statement {
    sid    = "ManageIsolatedResticBucket"
    effect = "Allow"
    actions = [
      "s3:CreateBucket", "s3:DeleteBucket", "s3:DeleteBucketPolicy", "s3:DeleteBucketTagging",
      "s3:DeleteBucketWebsite", "s3:Get*", "s3:ListBucket", "s3:ListBucketVersions",
      "s3:PutBucketPolicy", "s3:PutBucketPublicAccessBlock", "s3:PutBucketTagging",
      "s3:PutBucketVersioning", "s3:PutEncryptionConfiguration",
    ]
    resources = [local.restic_bucket_arn]
  }

  statement {
    sid    = "ManageIsolatedResticObjects"
    effect = "Allow"
    actions = [
      "s3:AbortMultipartUpload", "s3:DeleteObject", "s3:DeleteObjectVersion",
      "s3:GetObject", "s3:GetObjectAttributes", "s3:GetObjectTagging", "s3:GetObjectVersion",
      "s3:ListMultipartUploadParts", "s3:PutObject", "s3:PutObjectTagging",
    ]
    resources = ["${local.restic_bucket_arn}/*"]
  }

  statement {
    sid    = "DenyProductionTaggedResources"
    effect = "Deny"
    actions = [
      "backup:*", "ec2:*", "kms:*", "logs:*", "secretsmanager:*", "ssm:*",
    ]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/Environment"
      values   = ["production"]
    }
  }

  statement {
    sid    = "ManageTaggedDeployment"
    effect = "Allow"
    actions = [
      "backup:*", "ec2:*", "kms:*", "logs:*", "secretsmanager:*", "ssm:*",
    ]
    resources = ["*"]

    condition {
      test     = "StringEqualsIfExists"
      variable = "aws:RequestTag/Environment"
      values   = [var.environment]
    }

    condition {
      test     = "StringEqualsIfExists"
      variable = "aws:RequestTag/Project"
      values   = [var.project_name]
    }
  }

  statement {
    sid    = "ManageProjectIam"
    effect = "Allow"
    actions = [
      "iam:AttachRolePolicy", "iam:CreateInstanceProfile", "iam:CreatePolicy", "iam:CreateRole",
      "iam:DeleteInstanceProfile", "iam:DeletePolicy", "iam:DeleteRole", "iam:DeleteRolePolicy",
      "iam:DetachRolePolicy", "iam:Get*", "iam:List*", "iam:PassRole", "iam:PutRolePolicy",
      "iam:RemoveRoleFromInstanceProfile", "iam:AddRoleToInstanceProfile", "iam:Tag*", "iam:Untag*", "iam:UpdateAssumeRolePolicy",
    ]
    resources = [
      "arn:${data.aws_partition.current.partition}:iam::${local.account_id}:role/${var.project_name}-${var.environment}-*",
      "arn:${data.aws_partition.current.partition}:iam::${local.account_id}:policy/${var.project_name}-${var.environment}-*",
      "arn:${data.aws_partition.current.partition}:iam::${local.account_id}:instance-profile/${var.project_name}-${var.environment}-*",
    ]
  }

  statement {
    sid       = "ReadForApply"
    effect    = "Allow"
    actions   = local.plan_read_actions
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "apply" {
  name   = "apply-${var.environment}-deployment"
  role   = aws_iam_role.apply.id
  policy = data.aws_iam_policy_document.apply.json
}
