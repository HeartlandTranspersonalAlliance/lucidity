output "launch_template_ids" {
  description = "EC2 launch template IDs keyed by node role."
  value       = { for role, template in aws_launch_template.node : role => template.id }
}

output "launch_template_latest_versions" {
  description = "Latest numeric launch template versions keyed by node role for explicit pinning."
  value       = { for role, template in aws_launch_template.node : role => template.latest_version }
}

output "selected_ami_ids" {
  description = "Self-owned AMI IDs validated and pinned by the launch templates."
  value       = { for role, ami in data.aws_ami.selected : role => ami.image_id }
}

output "root_volume_settings" {
  description = "Auditable encrypted root-volume retention settings keyed by node role."
  value = {
    for role, template in aws_launch_template.node : role => {
      delete_on_termination = tobool(template.block_device_mappings[0].ebs[0].delete_on_termination)
      encrypted             = tobool(template.block_device_mappings[0].ebs[0].encrypted)
      kms_key_id            = template.block_device_mappings[0].ebs[0].kms_key_id
      volume_size           = template.block_device_mappings[0].ebs[0].volume_size
      volume_type           = template.block_device_mappings[0].ebs[0].volume_type
    }
  }
}
