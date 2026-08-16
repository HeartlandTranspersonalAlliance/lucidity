output "instance_ids" {
  description = "EC2 instance IDs keyed by node role."
  value       = { for role, instance in aws_instance.node : role => instance.id }
}

output "instance_arns" {
  description = "EC2 instance ARNs keyed by node role."
  value       = { for role, instance in aws_instance.node : role => instance.arn }
}

output "private_ips" {
  description = "Private VPC IPv4 addresses keyed by node role."
  value       = { for role, instance in aws_instance.node : role => instance.private_ip }
}

output "public_ips" {
  description = "Stable Elastic IPv4 addresses keyed by node role."
  value       = { for role, address in aws_eip.node : role => address.public_ip }
}

output "elastic_ip_allocation_ids" {
  description = "Elastic IP allocation IDs keyed by node role."
  value       = { for role, address in aws_eip.node : role => address.id }
}

output "availability_zones" {
  description = "Availability Zones used by each EC2 node role."
  value       = { for role, instance in aws_instance.node : role => instance.availability_zone }
}

output "instance_settings" {
  description = "Auditable placement, protection, addressing, and launch template settings keyed by node role."
  value = {
    for role, instance in aws_instance.node : role => {
      associate_public_ip_address        = instance.associate_public_ip_address
      disable_api_termination            = instance.disable_api_termination
      instance_initiated_shutdown_action = instance.instance_initiated_shutdown_behavior
      launch_template_version            = instance.launch_template[0].version
      subnet_id                          = instance.subnet_id
    }
  }
}
