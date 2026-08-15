locals {
  roles = {
    controller = {
      security_group_ids = [
        var.security_group_ids.controller,
        var.security_group_ids.web,
      ]
    }
    worker = {
      security_group_ids = [
        var.security_group_ids.application,
        var.security_group_ids.web,
      ]
    }
  }
  common_tags = merge(
    {
      Environment = var.environment
      Project     = var.project_name
    },
    var.tags,
  )
}

data "aws_ami" "selected" {
  for_each = local.roles

  owners = ["self"]

  filter {
    name   = "image-id"
    values = [var.ami_ids[each.key]]
  }
}

resource "aws_launch_template" "node" {
  for_each = local.roles

  name_prefix            = "${var.project_name}-${var.environment}-${each.key}-"
  description            = "Pinned ${var.project_name} ${var.environment} ${each.key} launch template"
  image_id               = var.ami_ids[each.key]
  instance_type          = var.instance_types[each.key]
  update_default_version = false
  vpc_security_group_ids = each.value.security_group_ids

  block_device_mappings {
    device_name = "/dev/xvda"

    ebs {
      delete_on_termination = true
      encrypted             = true
      kms_key_id            = var.root_volume_kms_key_arn
      volume_size           = var.root_volume_sizes[each.key]
      volume_type           = "gp3"
    }
  }

  credit_specification {
    cpu_credits = "standard"
  }

  iam_instance_profile {
    name = var.instance_profile_names[each.key]
  }

  metadata_options {
    http_endpoint               = "enabled"
    http_put_response_hop_limit = 2
    http_tokens                 = "required"
    instance_metadata_tags      = "enabled"
  }

  monitoring {
    enabled = true
  }

  tag_specifications {
    resource_type = "instance"
    tags = merge(local.common_tags, {
      Name = "${var.project_name}-${var.environment}-${each.key}"
      Role = each.key
    })
  }

  tag_specifications {
    resource_type = "volume"
    tags = merge(local.common_tags, {
      Name = "${var.project_name}-${var.environment}-${each.key}-root"
      Role = each.key
    })
  }

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-${var.environment}-${each.key}"
    Role = each.key
  })

  lifecycle {
    precondition {
      condition = (
        data.aws_ami.selected[each.key].architecture == "x86_64" &&
        data.aws_ami.selected[each.key].boot_mode == "uefi" &&
        data.aws_ami.selected[each.key].ena_support &&
        data.aws_ami.selected[each.key].imds_support == "v2.0" &&
        data.aws_ami.selected[each.key].root_device_type == "ebs" &&
        data.aws_ami.selected[each.key].state == "available" &&
        data.aws_ami.selected[each.key].virtualization_type == "hvm"
      )
      error_message = "The selected AMI must be a self-owned, available AMD64 UEFI HVM EBS image with ENA and IMDSv2 support."
    }
  }
}
