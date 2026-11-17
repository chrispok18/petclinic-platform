locals {
  name_prefix = "${var.project}-${var.environment}"

  common_tags = {
    Project     = var.project
    Environment = var.environment
    ManagedBy   = "terraform"
  }

  # technical-spec: VPC Network Design > CIDR Allocation (dev column)
  vpc_cidr_block      = "10.0.0.0/16"
  availability_zones  = ["eu-central-1a", "eu-central-1b"]
  public_subnet_cidrs = ["10.0.1.0/24", "10.0.2.0/24"]

  # technical-spec: CI/CD Pipeline > OIDC Federation
  github_repository = "chrispok18/spring-petclinic-microservices"
}

# PETPLAT-6, 8, 9 — VPC, public subnets, IGW, routing, EKS subnet tags, 4 security groups.
module "vpc" {
  source = "../../modules/vpc"

  name_prefix         = local.name_prefix
  cluster_name        = local.name_prefix # EKS cluster will be named petclinic-dev
  vpc_cidr_block      = local.vpc_cidr_block
  availability_zones  = local.availability_zones
  public_subnet_cidrs = local.public_subnet_cidrs

  tags = { Component = "networking" }
}

# PETPLAT-18, 19, 20 — 8 ECR repositories under petclinic-dev/.
module "ecr" {
  source = "../../modules/ecr"

  name_prefix          = local.name_prefix
  image_tag_mutability = "MUTABLE" # dev: mutable; prod: IMMUTABLE
  max_image_count      = 10
  force_delete         = true # dev only: lets teardown proceed even if repos still hold images

  tags = { Component = "registry" }
}

# PETPLAT-52 — GitHub Actions OIDC provider + ECR push role.
# No token.actions.githubusercontent.com provider existed in the account when this was written,
# so dev creates it. Prod must pass create_oidc_provider = false (provider is account-global).
module "github_oidc" {
  source = "../../modules/github-oidc"

  create_oidc_provider = true
  role_name            = "petclinic-github-actions-role"
  github_repository    = local.github_repository
  allowed_refs         = ["refs/heads/main"]
  ecr_repository_arns  = values(module.ecr.repository_arns)

  tags = { Component = "ci" }
}
