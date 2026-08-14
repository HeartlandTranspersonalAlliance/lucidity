output "instance_profile_names" {
  description = "SSM-enabled EC2 instance profile names keyed by node role."
  value       = { for role, profile in aws_iam_instance_profile.node : role => profile.name }
}

output "role_arns" {
  description = "EC2 IAM role ARNs keyed by node role."
  value       = { for role, node_role in aws_iam_role.node : role => node_role.arn }
}
