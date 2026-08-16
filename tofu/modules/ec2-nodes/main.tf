locals {
  roles = toset(["controller", "worker"])
  common_tags = merge(
    {
      Environment = var.environment
      Project     = var.project_name
    },
    var.tags,
  )
}

resource "aws_instance" "node" {
  for_each = local.roles

  associate_public_ip_address          = false
  disable_api_termination              = var.enable_termination_protection
  instance_initiated_shutdown_behavior = "stop"
  subnet_id                            = var.subnet_ids[each.key]

  launch_template {
    id      = var.launch_template_ids[each.key]
    version = tostring(var.launch_template_versions[each.key])
  }

  tags = merge(local.common_tags, {
    Name = var.node_names[each.key]
    Role = each.key
  })
}

resource "aws_eip" "node" {
  for_each = local.roles

  domain = "vpc"

  tags = merge(local.common_tags, {
    Name = "${var.node_names[each.key]}-eip"
    Role = each.key
  })
}

resource "aws_eip_association" "node" {
  for_each = local.roles

  allocation_id = aws_eip.node[each.key].id
  instance_id   = aws_instance.node[each.key].id
}
