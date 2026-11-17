output "role_arn" {
  description = "ARN of the GitHub Actions role (set as AWS_ROLE_ARN in GitHub secrets)"
  value       = aws_iam_role.github_actions.arn
}

output "role_name" {
  description = "Name of the GitHub Actions role"
  value       = aws_iam_role.github_actions.name
}

output "oidc_provider_arn" {
  description = "ARN of the GitHub OIDC provider (created or looked up)"
  value       = local.oidc_provider_arn
}
