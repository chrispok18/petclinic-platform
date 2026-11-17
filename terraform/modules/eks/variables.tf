variable "cluster_name" {
  description = "EKS cluster name (petclinic-{env})"
  type        = string
}

variable "kubernetes_version" {
  description = "Kubernetes version. Use a version in STANDARD support (check: aws eks describe-cluster-versions)."
  type        = string
}

variable "subnet_ids" {
  description = "Subnets for the control-plane ENIs and the node group (public, AZ a + b)"
  type        = list(string)

  validation {
    condition     = length(var.subnet_ids) >= 2
    error_message = "EKS requires subnets in at least two AZs."
  }
}

variable "cluster_security_group_id" {
  description = "Custom cluster SG from the vpc module, attached to the control-plane ENIs in addition to the EKS primary SG"
  type        = string
}

variable "node_security_group_id" {
  description = "Custom node SG from the vpc module, attached to every node (and therefore every pod) via the launch template"
  type        = string
}

variable "public_access_cidrs" {
  description = "CIDRs allowed to reach the public API endpoint"
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "cluster_log_types" {
  description = "Control-plane log types sent to CloudWatch"
  type        = list(string)
  default     = ["api", "audit", "authenticator"]
}

variable "cluster_log_retention_days" {
  description = "Retention for the /aws/eks/<cluster>/cluster log group"
  type        = number
  default     = 7
}

variable "node_ami_type" {
  description = "Managed node group AMI type"
  type        = string
  default     = "AL2023_ARM_64_STANDARD"
}

variable "node_instance_types" {
  description = "Node instance types"
  type        = list(string)
  default     = ["t4g.small"]
}

variable "node_disk_size" {
  description = "Root EBS volume size (GiB) per node"
  type        = number
  default     = 20
}

variable "node_min_size" {
  description = "Node group minimum size"
  type        = number
  default     = 2
}

variable "node_max_size" {
  description = "Node group maximum size"
  type        = number
  default     = 8
}

variable "node_desired_size" {
  description = "Node group desired size"
  type        = number
  default     = 5

  validation {
    condition     = var.node_desired_size >= 1
    error_message = "node_desired_size must be at least 1."
  }
}

variable "addon_versions" {
  description = "EKS managed add-ons => pinned version (aws eks describe-addon-versions --kubernetes-version <v> --addon-name <name>)"
  type        = map(string)
}

variable "tags" {
  description = "Additional tags merged onto every resource (provider default_tags supply Project/Environment/ManagedBy)"
  type        = map(string)
  default     = {}
}
