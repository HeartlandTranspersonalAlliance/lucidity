data "aws_caller_identity" "current" {}

data "aws_partition" "current" {}

locals {
  account_id                             = data.aws_caller_identity.current.account_id
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

resource "aws_kms_key" "ami_snapshot" {
  description             = "Encrypts ${var.project_name} bootc AMI snapshots"
  deletion_window_in_days = 30
  enable_key_rotation     = true

  tags = merge(local.common_tags, { Name = "${local.resource_prefix}-ami-snapshots" })
}

resource "aws_kms_alias" "ami_snapshot" {
  name          = "alias/${local.resource_prefix}-ami-snapshots"
  target_key_id = aws_kms_key.ami_snapshot.key_id
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
  description          = "GitHub Actions role for ${var.project_name} AMI validation and retained releases"
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
    sid     = "StartTaggedValidationSnapshot"
    effect  = "Allow"
    actions = ["ebs:StartSnapshot"]
    resources = [
      "arn:${data.aws_partition.current.partition}:ec2:${var.aws_region}::snapshot/*",
    ]

    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/Project"
      values   = [var.project_name]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/Purpose"
      values   = ["ami-release", "ami-validation"]
    }
  }

  statement {
    sid    = "WriteTaggedValidationSnapshot"
    effect = "Allow"
    actions = [
      "ebs:CompleteSnapshot",
      "ebs:PutSnapshotBlock",
    ]
    resources = [
      "arn:${data.aws_partition.current.partition}:ec2:${var.aws_region}::snapshot/*",
    ]

    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/Purpose"
      values   = ["ami-release", "ami-validation"]
    }
  }

  statement {
    sid    = "UseAmiSnapshotKey"
    effect = "Allow"
    actions = [
      "kms:Decrypt",
      "kms:DescribeKey",
      "kms:GenerateDataKey",
      "kms:GenerateDataKeyWithoutPlaintext",
      "kms:ReEncrypt*",
    ]
    resources = [aws_kms_key.ami_snapshot.arn]
  }

  statement {
    sid       = "AuthenticateToEcr"
    effect    = "Allow"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  statement {
    sid    = "PullImmutableAmiSource"
    effect = "Allow"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:BatchGetImage",
      "ecr:GetDownloadUrlForLayer",
    ]
    resources = var.source_repository_arns
  }

  statement {
    sid     = "CreateAmiSnapshotKeyGrant"
    effect  = "Allow"
    actions = ["kms:CreateGrant"]
    resources = [
      aws_kms_key.ami_snapshot.arn,
    ]

    condition {
      test     = "Bool"
      variable = "kms:GrantIsForAWSResource"
      values   = ["true"]
    }
  }

  statement {
    sid    = "ValidateAndCleanUpAmi"
    effect = "Allow"
    actions = [
      "ec2:DeleteSnapshot",
      "ec2:DeregisterImage",
      "ec2:DescribeImages",
      "ec2:DescribeInstances",
      "ec2:DescribeInstanceStatus",
      "ec2:DescribeSecurityGroups",
      "ec2:DescribeSnapshots",
      "ec2:RegisterImage",
    ]
    resources = ["*"]
  }

  statement {
    sid     = "TagValidationImageAndSnapshot"
    effect  = "Allow"
    actions = ["ec2:CreateTags"]
    resources = [
      "arn:${data.aws_partition.current.partition}:ec2:${var.aws_region}::image/*",
      "arn:${data.aws_partition.current.partition}:ec2:${var.aws_region}::snapshot/*",
    ]

    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/Project"
      values   = [var.project_name]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/Purpose"
      values   = ["ami-release", "ami-validation"]
    }
  }

  dynamic "statement" {
    for_each = var.enable_launch_validation ? [1] : []

    content {
      sid     = "UseTaggedValidationImageAndSnapshot"
      effect  = "Allow"
      actions = ["ec2:RunInstances"]
      resources = [
        # EC2 image and snapshot ARNs intentionally have an empty account field.
        "arn:${data.aws_partition.current.partition}:ec2:${var.aws_region}::image/*",
        "arn:${data.aws_partition.current.partition}:ec2:${var.aws_region}::snapshot/*",
      ]

      condition {
        test     = "StringEquals"
        variable = "ec2:ResourceTag/Purpose"
        values   = ["ami-release", "ami-validation"]
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
        "arn:${data.aws_partition.current.partition}:ec2:${var.aws_region}:${local.account_id}:instance/*",
        "arn:${data.aws_partition.current.partition}:ec2:${var.aws_region}:${local.account_id}:network-interface/*",
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
