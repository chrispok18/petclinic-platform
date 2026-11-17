variable "aws_region" {
  description = "AWS region for all dev resources"
  type        = string
  default     = "eu-central-1"
}

variable "environment" {
  description = "Deployment environment name"
  type        = string
  default     = "dev"

  validation {
    condition     = contains(["dev", "prod"], var.environment)
    error_message = "environment must be \"dev\" or \"prod\"."
  }
}

variable "project" {
  description = "Project name, used as the prefix in petclinic-{env}-{resource} names"
  type        = string
  default     = "petclinic"
}

variable "eks_node_desired_size" {
  description = "Desired number of t4g.small nodes in the dev node group (min 2, max 8)"
  type        = number
  default     = 5

  validation {
    condition     = var.eks_node_desired_size >= 2 && var.eks_node_desired_size <= 8
    error_message = "eks_node_desired_size must be between 2 and 8."
  }
}
