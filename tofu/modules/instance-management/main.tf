data "aws_partition" "current" {}

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

resource "aws_iam_role_policy_attachment" "controller_additional" {
  for_each = var.controller_policy_arns

  policy_arn = each.value
  role       = aws_iam_role.node["controller"].name
}

resource "aws_iam_instance_profile" "node" {
  for_each = local.node_roles

  name = "${local.resource_prefix}-${each.key}-profile"
  role = aws_iam_role.node[each.key].name

  tags = merge(local.common_tags, { Role = each.key })
}
