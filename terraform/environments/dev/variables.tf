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
