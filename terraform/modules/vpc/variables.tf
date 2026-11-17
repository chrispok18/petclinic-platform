variable "name_prefix" {
  description = "Resource name prefix, petclinic-{env}"
  type        = string
}

variable "cluster_name" {
  description = "EKS cluster name used in kubernetes.io/cluster/<name> subnet tags. Defaults to name_prefix (petclinic-{env})."
  type        = string
  default     = null
}

variable "vpc_cidr_block" {
  description = "CIDR block for the VPC"
  type        = string

  validation {
    condition     = can(cidrhost(var.vpc_cidr_block, 0))
    error_message = "vpc_cidr_block must be a valid IPv4 CIDR."
  }
}

variable "availability_zones" {
  description = "Availability zones for the public subnets (one subnet per AZ)"
  type        = list(string)
}

variable "public_subnet_cidrs" {
  description = "CIDR blocks for the public subnets, same order and length as availability_zones"
  type        = list(string)

  validation {
    condition     = length(var.public_subnet_cidrs) >= 2
    error_message = "EKS requires at least two subnets in different AZs."
  }
}

variable "tags" {
  description = "Additional tags merged onto every resource (provider default_tags supply Project/Environment/ManagedBy)"
  type        = map(string)
  default     = {}
}
