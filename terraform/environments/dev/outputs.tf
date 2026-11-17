output "aws_region" {
  description = "AWS region the dev environment is deployed to"
  value       = var.aws_region
}

output "environment" {
  description = "Environment name"
  value       = var.environment
}

output "name_prefix" {
  description = "Resource name prefix (petclinic-{env})"
  value       = local.name_prefix
}
