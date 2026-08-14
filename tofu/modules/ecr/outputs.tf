output "repository_arns" {
  description = "ECR repository ARNs keyed by bootc image role."
  value       = { for role, repository in aws_ecr_repository.bootc : role => repository.arn }
}

output "repository_names" {
  description = "ECR repository names keyed by bootc image role."
  value       = { for role, repository in aws_ecr_repository.bootc : role => repository.name }
}

output "repository_urls" {
  description = "ECR repository URLs keyed by bootc image role."
  value       = { for role, repository in aws_ecr_repository.bootc : role => repository.repository_url }
}
