output "repository_urls" {
  description = "Map of service name => ECR repository URL"
  value       = { for k, r in aws_ecr_repository.service : k => r.repository_url }
}

output "repository_arns" {
  description = "Map of service name => ECR repository ARN"
  value       = { for k, r in aws_ecr_repository.service : k => r.arn }
}

output "repository_names" {
  description = "Map of service name => ECR repository name"
  value       = { for k, r in aws_ecr_repository.service : k => r.name }
}
