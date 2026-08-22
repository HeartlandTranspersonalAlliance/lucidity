data "aws_caller_identity" "current" {}

data "aws_partition" "current" {}

locals {
  account_id              = data.aws_caller_identity.current.account_id
  github_repository_parts = split("/", var.github_repository)
  github_subject = var.github_environment == null ? (
    "repo:${local.github_repository_parts[0]}@${var.github_repository_owner_id}/${local.github_repository_parts[1]}@${var.github_repository_id}:ref:refs/heads/${var.github_branch}"
    ) : (
    "repo:${local.github_repository_parts[0]}@${var.github_repository_owner_id}/${local.github_repository_parts[1]}@${var.github_repository_id}:environment:${var.github_environment}"
  )
  resource_prefix = "${var.project_name}-${var.environment}"
  common_tags = merge(
    {
      Environment = var.environment
      Project     = var.project_name
    },
    var.tags,
  )
}

data "aws_iam_policy_document" "github_assume_role" {
  statement {
    sid     = "GitHubActionsDeploymentValidation"
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
  name                 = "${local.resource_prefix}-github-deployment-validation"
  assume_role_policy   = data.aws_iam_policy_document.github_assume_role.json
  description          = "GitHub Actions role for ${var.project_name} ${var.environment} deployment enrollment and validation"
  max_session_duration = 3600

  tags = local.common_tags
}

data "aws_iam_policy_document" "github" {
  statement {
    sid    = "DiscoverDeploymentNodes"
    effect = "Allow"
    actions = [
      "ec2:DescribeInstances",
      "ec2:DescribeSecurityGroups",
      "ec2:DescribeVolumes",
      "ssm:DescribeInstanceInformation",
      "ssm:GetCommandInvocation",
    ]
    resources = ["*"]
  }

  statement {
    sid       = "RunApprovedShellDocument"
    effect    = "Allow"
    actions   = ["ssm:SendCommand"]
    resources = ["arn:${data.aws_partition.current.partition}:ssm:${var.aws_region}::document/AWS-RunShellScript"]
  }

  statement {
    sid       = "RunOnTaggedDeploymentNodes"
    effect    = "Allow"
    actions   = ["ssm:SendCommand"]
    resources = ["arn:${data.aws_partition.current.partition}:ec2:${var.aws_region}:${local.account_id}:instance/*"]

    condition {
      test     = "StringEquals"
      variable = "ssm:resourceTag/Project"
      values   = [var.project_name]
    }

    condition {
      test     = "StringEquals"
      variable = "ssm:resourceTag/Environment"
      values   = [var.environment]
    }

    condition {
      test     = "StringEquals"
      variable = "ssm:resourceTag/Role"
      values   = ["controller", "worker"]
    }
  }
}

resource "aws_iam_role_policy" "github" {
  name   = "validate-tagged-${var.environment}-deployment"
  role   = aws_iam_role.github.id
  policy = data.aws_iam_policy_document.github.json
}
