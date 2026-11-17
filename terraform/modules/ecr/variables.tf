variable "name_prefix" {
  description = "Repository namespace prefix, petclinic-{env}"
  type        = string
}

variable "service_names" {
  description = "Services that get an ECR repository (petclinic-{env}/{service})"
  type        = list(string)
  default = [
    "config-server",
    "discovery-server",
    "api-gateway",
    "customers-service",
    "visits-service",
    "vets-service",
    "genai-service",
    "admin-server",
  ]
}

variable "image_tag_mutability" {
  description = "Tag mutability: MUTABLE (dev) or IMMUTABLE (prod)"
  type        = string
  default     = "IMMUTABLE"

  validation {
    condition     = contains(["MUTABLE", "IMMUTABLE"], var.image_tag_mutability)
    error_message = "image_tag_mutability must be MUTABLE or IMMUTABLE."
  }
}

variable "max_image_count" {
  description = "Lifecycle policy: number of most recent images to keep per repository"
  type        = number
  default     = 10
}

variable "force_delete" {
  description = "Allow deleting repositories that still contain images (keep false in prod)"
  type        = bool
  default     = false
}

variable "tags" {
  description = "Additional tags merged onto every repository"
  type        = map(string)
  default     = {}
}
