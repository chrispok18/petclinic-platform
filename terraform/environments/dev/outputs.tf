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

# --- VPC ---------------------------------------------------------------------

output "vpc_id" {
  description = "Dev VPC ID"
  value       = module.vpc.vpc_id
}

output "public_subnet_ids" {
  description = "Dev public subnet IDs (eu-central-1a, eu-central-1b)"
  value       = module.vpc.public_subnet_ids
}

output "eks_cluster_security_group_id" {
  description = "EKS cluster security group ID"
  value       = module.vpc.eks_cluster_security_group_id
}

output "eks_node_security_group_id" {
  description = "EKS node security group ID"
  value       = module.vpc.eks_node_security_group_id
}

output "rds_security_group_id" {
  description = "RDS security group ID"
  value       = module.vpc.rds_security_group_id
}

output "alb_security_group_id" {
  description = "ALB security group ID"
  value       = module.vpc.alb_security_group_id
}

# --- ECR ---------------------------------------------------------------------

output "ecr_repository_urls" {
  description = "Map of service name => ECR repository URL"
  value       = module.ecr.repository_urls
}

# --- GitHub OIDC -------------------------------------------------------------

output "github_actions_role_arn" {
  description = "IAM role ARN for GitHub Actions (AWS_ROLE_ARN secret)"
  value       = module.github_oidc.role_arn
}
