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

  # Newest Kubernetes version in STANDARD support in eu-central-1 (checked 2026-11-17 with
  # `aws eks describe-cluster-versions`; standard support ends 2027-12-01).
  kubernetes_version = "1.37"

  # Default add-on versions for 1.37 (`aws eks describe-addon-versions`, checked 2026-11-17).
  eks_addon_versions = {
    "coredns"    = "v1.14.7-eksbuild.35"
    "kube-proxy" = "v1.37.0-eksbuild.39"
    "vpc-cni"    = "v1.22.4-eksbuild.14"
  }
}

data "aws_caller_identity" "current" {}

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

# PETPLAT-12, 13, 14, 15, 84 — EKS cluster, OIDC provider, managed node group, pinned add-ons.
# aws-ebs-csi-driver intentionally omitted (no PersistentVolumes in dev).
module "eks" {
  source = "../../modules/eks"

  cluster_name              = local.name_prefix
  kubernetes_version        = local.kubernetes_version
  subnet_ids                = module.vpc.public_subnet_ids
  cluster_security_group_id = module.vpc.eks_cluster_security_group_id
  node_security_group_id    = module.vpc.eks_node_security_group_id

  node_ami_type       = "AL2023_ARM_64_STANDARD"
  node_instance_types = ["t4g.small"]
  node_min_size       = 2
  node_max_size       = 8
  node_desired_size   = var.eks_node_desired_size

  addon_versions = local.eks_addon_versions

  tags = { Component = "compute" }
}

# PETPLAT-22, 23, 25 — MySQL 8.0 + credentials secret petclinic/dev/rds-credentials.
module "rds" {
  source = "../../modules/rds"

  name_prefix       = local.name_prefix
  subnet_ids        = module.vpc.public_subnet_ids
  security_group_id = module.vpc.rds_security_group_id

  instance_class      = "db.t4g.micro"
  skip_final_snapshot = true  # dev: disposable
  deletion_protection = false # dev: disposable
  apply_immediately   = true

  secret_name                 = "${var.project}/${var.environment}/rds-credentials"
  secret_recovery_window_days = 0 # dev: name reusable immediately after destroy

  tags = { Component = "database" }
}

# --- IRSA (technical-spec: IRSA Roles) ---------------------------------------

data "aws_iam_policy_document" "eso" {
  statement {
    sid       = "ReadPetclinicSecrets"
    effect    = "Allow"
    actions   = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]
    resources = ["arn:aws:secretsmanager:${var.aws_region}:${data.aws_caller_identity.current.account_id}:secret:${var.project}/*"]
  }
}

module "irsa_external_secrets" {
  source = "../../modules/irsa-role"

  role_name         = "${local.name_prefix}-eso-role"
  oidc_provider_arn = module.eks.oidc_provider_arn
  oidc_provider_url = module.eks.oidc_provider_url
  namespace         = "external-secrets"
  service_account   = "external-secrets-sa"
  policy_json       = data.aws_iam_policy_document.eso.json

  tags = { Component = "secrets" }
}

# Official policy from kubernetes-sigs/aws-load-balancer-controller v3.6.3 (docs/install/iam_policy.json).
module "irsa_lb_controller" {
  source = "../../modules/irsa-role"

  role_name         = "${local.name_prefix}-lb-controller-role"
  oidc_provider_arn = module.eks.oidc_provider_arn
  oidc_provider_url = module.eks.oidc_provider_url
  namespace         = "kube-system"
  service_account   = "aws-load-balancer-controller"
  policy_json       = file("${path.module}/../../policies/aws-load-balancer-controller-iam-policy.json")

  tags = { Component = "ingress" }
}
