# VPC module (technical-spec: VPC Network Design, Security Groups). PETPLAT-6, 8, 9.
# All-public subnet design: no NAT, no private subnets. Security groups are the perimeter (ADR-0001).

locals {
  cluster_name = coalesce(var.cluster_name, var.name_prefix)
}

resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr_block
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = merge(var.tags, { Name = "${var.name_prefix}-vpc" })
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = merge(var.tags, { Name = "${var.name_prefix}-igw" })
}

resource "aws_subnet" "public" {
  count = length(var.public_subnet_cidrs)

  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.public_subnet_cidrs[count.index]
  availability_zone       = var.availability_zones[count.index]
  map_public_ip_on_launch = true

  tags = merge(var.tags, {
    Name                                          = "${var.name_prefix}-public-${var.availability_zones[count.index]}"
    "kubernetes.io/cluster/${local.cluster_name}" = "shared"
    "kubernetes.io/role/elb"                      = "1"
  })
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  tags = merge(var.tags, { Name = "${var.name_prefix}-public-rt" })
}

resource "aws_route" "public_internet" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.main.id
}

resource "aws_route_table_association" "public" {
  count = length(aws_subnet.public)

  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# Strip all rules from the VPC default SG so nothing silently relies on it (deny-all default).
resource "aws_default_security_group" "default" {
  vpc_id = aws_vpc.main.id

  tags = merge(var.tags, { Name = "${var.name_prefix}-default-sg-unused" })
}

# ---------------------------------------------------------------------------
# Security groups. Rules are standalone resources to avoid SG <-> SG cycles.
# ---------------------------------------------------------------------------

resource "aws_security_group" "eks_cluster" {
  name        = "${var.name_prefix}-eks-cluster-sg"
  description = "EKS control plane - API server access from worker nodes"
  vpc_id      = aws_vpc.main.id

  tags = merge(var.tags, { Name = "${var.name_prefix}-eks-cluster-sg" })
}

resource "aws_security_group" "eks_nodes" {
  name        = "${var.name_prefix}-eks-node-sg"
  description = "EKS worker nodes"
  vpc_id      = aws_vpc.main.id

  tags = merge(var.tags, { Name = "${var.name_prefix}-eks-node-sg" })
}

resource "aws_security_group" "rds" {
  name        = "${var.name_prefix}-rds-sg"
  description = "RDS MySQL - 3306 from EKS nodes only"
  vpc_id      = aws_vpc.main.id

  tags = merge(var.tags, { Name = "${var.name_prefix}-rds-sg" })
}

resource "aws_security_group" "alb" {
  name        = "${var.name_prefix}-alb-sg"
  description = "Public ALB - HTTP and HTTPS from internet"
  vpc_id      = aws_vpc.main.id

  tags = merge(var.tags, { Name = "${var.name_prefix}-alb-sg" })
}

# --- EKS cluster SG ---------------------------------------------------------

resource "aws_vpc_security_group_ingress_rule" "cluster_https_from_nodes" {
  security_group_id            = aws_security_group.eks_cluster.id
  description                  = "API server access from nodes"
  ip_protocol                  = "tcp"
  from_port                    = 443
  to_port                      = 443
  referenced_security_group_id = aws_security_group.eks_nodes.id

  tags = merge(var.tags, { Name = "${var.name_prefix}-cluster-in-443-nodes" })
}

resource "aws_vpc_security_group_egress_rule" "cluster_all_out" {
  security_group_id = aws_security_group.eks_cluster.id
  description       = "All outbound"
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"

  tags = merge(var.tags, { Name = "${var.name_prefix}-cluster-out-all" })
}

# --- EKS node SG ------------------------------------------------------------

resource "aws_vpc_security_group_ingress_rule" "nodes_all_from_cluster" {
  security_group_id            = aws_security_group.eks_nodes.id
  description                  = "All from cluster SG"
  ip_protocol                  = "-1"
  referenced_security_group_id = aws_security_group.eks_cluster.id

  tags = merge(var.tags, { Name = "${var.name_prefix}-nodes-in-all-cluster" })
}

resource "aws_vpc_security_group_ingress_rule" "nodes_self" {
  security_group_id            = aws_security_group.eks_nodes.id
  description                  = "Inter-node communication"
  ip_protocol                  = "-1"
  referenced_security_group_id = aws_security_group.eks_nodes.id

  tags = merge(var.tags, { Name = "${var.name_prefix}-nodes-in-all-self" })
}

resource "aws_vpc_security_group_ingress_rule" "nodes_kubelet_from_cluster" {
  security_group_id            = aws_security_group.eks_nodes.id
  description                  = "Kubelet API from cluster"
  ip_protocol                  = "tcp"
  from_port                    = 10250
  to_port                      = 10250
  referenced_security_group_id = aws_security_group.eks_cluster.id

  tags = merge(var.tags, { Name = "${var.name_prefix}-nodes-in-10250-cluster" })
}

resource "aws_vpc_security_group_ingress_rule" "nodes_nodeport_from_alb" {
  security_group_id            = aws_security_group.eks_nodes.id
  description                  = "NodePort services from ALB"
  ip_protocol                  = "tcp"
  from_port                    = 30000
  to_port                      = 32767
  referenced_security_group_id = aws_security_group.alb.id

  tags = merge(var.tags, { Name = "${var.name_prefix}-nodes-in-nodeport-alb" })
}

# Pairs with the ALB 8080 egress rule: health checks and ip-mode targets (AWS LB Controller).
resource "aws_vpc_security_group_ingress_rule" "nodes_8080_from_alb" {
  security_group_id            = aws_security_group.eks_nodes.id
  description                  = "Health checks and ip-mode targets from ALB"
  ip_protocol                  = "tcp"
  from_port                    = 8080
  to_port                      = 8080
  referenced_security_group_id = aws_security_group.alb.id

  tags = merge(var.tags, { Name = "${var.name_prefix}-nodes-in-8080-alb" })
}

resource "aws_vpc_security_group_egress_rule" "nodes_all_out" {
  security_group_id = aws_security_group.eks_nodes.id
  description       = "All outbound"
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"

  tags = merge(var.tags, { Name = "${var.name_prefix}-nodes-out-all" })
}

# --- RDS SG -----------------------------------------------------------------
# 3306 from EKS node SG ONLY. No egress rules (RDS initiates no connections).

resource "aws_vpc_security_group_ingress_rule" "rds_mysql_from_nodes" {
  security_group_id            = aws_security_group.rds.id
  description                  = "MySQL from EKS nodes"
  ip_protocol                  = "tcp"
  from_port                    = 3306
  to_port                      = 3306
  referenced_security_group_id = aws_security_group.eks_nodes.id

  tags = merge(var.tags, { Name = "${var.name_prefix}-rds-in-3306-nodes" })
}

# --- ALB SG -----------------------------------------------------------------
# The only 0.0.0.0/0 ingress allowed by the security rules: ALB on 80/443.

resource "aws_vpc_security_group_ingress_rule" "alb_http" {
  security_group_id = aws_security_group.alb.id
  description       = "HTTP from internet"
  ip_protocol       = "tcp"
  from_port         = 80
  to_port           = 80
  cidr_ipv4         = "0.0.0.0/0"

  tags = merge(var.tags, { Name = "${var.name_prefix}-alb-in-80" })
}

resource "aws_vpc_security_group_ingress_rule" "alb_https" {
  security_group_id = aws_security_group.alb.id
  description       = "HTTPS from internet"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  cidr_ipv4         = "0.0.0.0/0"

  tags = merge(var.tags, { Name = "${var.name_prefix}-alb-in-443" })
}

resource "aws_vpc_security_group_egress_rule" "alb_to_nodeports" {
  security_group_id            = aws_security_group.alb.id
  description                  = "To nodes (target group NodePorts)"
  ip_protocol                  = "tcp"
  from_port                    = 30000
  to_port                      = 32767
  referenced_security_group_id = aws_security_group.eks_nodes.id

  tags = merge(var.tags, { Name = "${var.name_prefix}-alb-out-nodeport-nodes" })
}

resource "aws_vpc_security_group_egress_rule" "alb_healthcheck" {
  security_group_id            = aws_security_group.alb.id
  description                  = "Health checks to nodes"
  ip_protocol                  = "tcp"
  from_port                    = 8080
  to_port                      = 8080
  referenced_security_group_id = aws_security_group.eks_nodes.id

  tags = merge(var.tags, { Name = "${var.name_prefix}-alb-out-8080-nodes" })
}
