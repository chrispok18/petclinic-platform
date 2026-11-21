# EKS module (technical-spec: EKS Cluster). PETPLAT-12, 13, 14, 15, 84.
#
# Approved deviations from the spec:
#   - kubernetes_version: newest version in STANDARD support (spec says 1.29, which is extended support).
#   - AMI: AL2023_ARM_64_STANDARD (AL2 is not published for new Kubernetes versions).
#   - Node group sizing set per environment (dev: 2x t4g.large, min 2 / max 2, vCPU quota).
#   - aws-ebs-csi-driver skipped: Prometheus/Grafana run without PersistentVolumes.
#
# Node security groups, IMPORTANT:
# A managed node group WITHOUT a launch template gets ONLY the EKS-created cluster primary SG
# ("eks-cluster-sg-<name>-<id>"). The custom node SG from the vpc module would never be attached,
# so the RDS rule (3306 from node SG) and the ALB rule (8080 from ALB SG to node SG) would not match.
# This module therefore uses a launch template listing BOTH SGs. When a launch template specifies SGs,
# EKS does not add the primary SG on its own, so it is listed explicitly to keep control-plane <-> node traffic.
# The VPC CNI gives pod IPs from secondary ENIs that inherit the primary ENI's SGs, so pods carry both SGs too.

data "aws_partition" "current" {}

locals {
  cluster_name = var.cluster_name
}

# --- Cluster IAM role -------------------------------------------------------

data "aws_iam_policy_document" "cluster_assume" {
  statement {
    actions = ["sts:AssumeRole", "sts:TagSession"]
    principals {
      type        = "Service"
      identifiers = ["eks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "cluster" {
  name               = "${local.cluster_name}-cluster-role"
  assume_role_policy = data.aws_iam_policy_document.cluster_assume.json

  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "cluster" {
  role       = aws_iam_role.cluster.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonEKSClusterPolicy"
}

# --- Control plane logs -----------------------------------------------------
# Created explicitly so retention is bounded and the group is removed on destroy.

resource "aws_cloudwatch_log_group" "cluster" {
  name              = "/aws/eks/${local.cluster_name}/cluster"
  retention_in_days = var.cluster_log_retention_days

  tags = var.tags
}

# --- Cluster ----------------------------------------------------------------

resource "aws_eks_cluster" "this" {
  name     = local.cluster_name
  version  = var.kubernetes_version
  role_arn = aws_iam_role.cluster.arn

  enabled_cluster_log_types = var.cluster_log_types

  vpc_config {
    subnet_ids              = var.subnet_ids
    security_group_ids      = [var.cluster_security_group_id] # extra SG on control-plane ENIs
    endpoint_public_access  = true
    endpoint_private_access = true # nodes reach the API server inside the VPC
    public_access_cidrs     = var.public_access_cidrs
  }

  access_config {
    authentication_mode                         = "API_AND_CONFIG_MAP"
    bootstrap_cluster_creator_admin_permissions = true # the IAM identity running terraform gets cluster-admin
  }

  # Never drift into paid extended support: EKS auto-upgrades at end of standard support instead.
  upgrade_policy {
    support_type = "STANDARD"
  }

  tags = merge(var.tags, { Name = local.cluster_name })

  depends_on = [
    aws_iam_role_policy_attachment.cluster,
    aws_cloudwatch_log_group.cluster,
  ]
}

# --- OIDC provider for IRSA -------------------------------------------------

data "tls_certificate" "oidc" {
  url = aws_eks_cluster.this.identity[0].oidc[0].issuer
}

resource "aws_iam_openid_connect_provider" "this" {
  url             = aws_eks_cluster.this.identity[0].oidc[0].issuer
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.oidc.certificates[0].sha1_fingerprint]

  tags = merge(var.tags, { Name = "${local.cluster_name}-oidc" })
}

# --- Node IAM role ----------------------------------------------------------

data "aws_iam_policy_document" "node_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "node" {
  name               = "${local.cluster_name}-node-role"
  assume_role_policy = data.aws_iam_policy_document.node_assume.json

  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "node" {
  for_each = toset([
    "AmazonEKSWorkerNodePolicy",
    "AmazonEKS_CNI_Policy",
    "AmazonEC2ContainerRegistryReadOnly",
  ])

  role       = aws_iam_role.node.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/${each.value}"
}

# --- Launch template (attaches the node SG, encrypts the root volume) ------

resource "aws_launch_template" "nodes" {
  name_prefix = "${local.cluster_name}-nodes-"
  description = "EKS managed node group ${local.cluster_name}-nodes"

  vpc_security_group_ids = [
    aws_eks_cluster.this.vpc_config[0].cluster_security_group_id, # EKS primary SG: control plane <-> nodes
    var.node_security_group_id,                                   # custom node SG: matched by RDS and ALB rules
  ]

  block_device_mappings {
    device_name = "/dev/xvda" # AL2023 root device
    ebs {
      volume_size           = var.node_disk_size
      volume_type           = "gp3"
      encrypted             = true
      delete_on_termination = true
    }
  }

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1 # pods cannot borrow the node role; workloads use IRSA
  }

  tag_specifications {
    resource_type = "instance"
    tags          = merge(var.tags, { Name = "${local.cluster_name}-node" })
  }

  tag_specifications {
    resource_type = "volume"
    tags          = merge(var.tags, { Name = "${local.cluster_name}-node-root" })
  }

  tags = var.tags

  lifecycle {
    create_before_destroy = true
  }
}

# --- Managed node group -----------------------------------------------------

resource "aws_eks_node_group" "this" {
  cluster_name    = aws_eks_cluster.this.name
  node_group_name = "${local.cluster_name}-nodes"
  node_role_arn   = aws_iam_role.node.arn
  subnet_ids      = var.subnet_ids

  ami_type       = var.node_ami_type
  instance_types = var.node_instance_types
  capacity_type  = "ON_DEMAND"

  scaling_config {
    min_size     = var.node_min_size
    max_size     = var.node_max_size
    desired_size = var.node_desired_size
  }

  update_config {
    max_unavailable = 1
  }

  launch_template {
    id      = aws_launch_template.nodes.id
    version = aws_launch_template.nodes.latest_version
  }

  tags = merge(var.tags, { Name = "${local.cluster_name}-nodes" })

  depends_on = [aws_iam_role_policy_attachment.node]
}

# --- Managed add-ons (versions pinned) --------------------------------------
# Installed after the node group so coredns can schedule; OVERWRITE adopts the
# self-managed copies EKS bootstraps at cluster creation.

resource "aws_eks_addon" "this" {
  for_each = var.addon_versions

  cluster_name                = aws_eks_cluster.this.name
  addon_name                  = each.key
  addon_version               = each.value
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  tags = var.tags

  depends_on = [aws_eks_node_group.this]
}
