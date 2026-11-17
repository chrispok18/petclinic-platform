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

# --- EKS ---------------------------------------------------------------------

output "eks_cluster_name" {
  description = "EKS cluster name"
  value       = module.eks.cluster_name
}

output "eks_cluster_endpoint" {
  description = "EKS API server endpoint"
  value       = module.eks.cluster_endpoint
}

output "eks_cluster_primary_security_group_id" {
  description = "EKS-created primary SG (on control plane and nodes, alongside the custom node SG)"
  value       = module.eks.cluster_primary_security_group_id
}

output "eks_oidc_provider_arn" {
  description = "IAM OIDC provider ARN for IRSA"
  value       = module.eks.oidc_provider_arn
}

output "eks_update_kubeconfig_command" {
  description = "Command to configure kubectl for this cluster"
  value       = "aws eks update-kubeconfig --region ${var.aws_region} --name ${module.eks.cluster_name}"
}

# --- RDS ---------------------------------------------------------------------

output "rds_address" {
  description = "RDS MySQL hostname"
  value       = module.rds.db_address
}

output "rds_jdbc_url" {
  description = "JDBC URL for customers/visits/vets services"
  value       = module.rds.jdbc_url
}

output "rds_credentials_secret_name" {
  description = "Secrets Manager name of the RDS credentials JSON"
  value       = module.rds.credentials_secret_name
}

# --- IRSA --------------------------------------------------------------------

output "external_secrets_role_arn" {
  description = "IRSA role ARN for external-secrets/external-secrets-sa"
  value       = module.irsa_external_secrets.role_arn
}

output "lb_controller_role_arn" {
  description = "IRSA role ARN for kube-system/aws-load-balancer-controller"
  value       = module.irsa_lb_controller.role_arn
}
