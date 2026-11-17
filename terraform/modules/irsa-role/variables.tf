variable "role_name" {
  description = "IAM role name (petclinic-{env}-{component}-role)"
  type        = string
}

variable "oidc_provider_arn" {
  description = "EKS IAM OIDC provider ARN"
  type        = string
}

variable "oidc_provider_url" {
  description = "EKS OIDC issuer URL without https://"
  type        = string

  validation {
    condition     = !startswith(var.oidc_provider_url, "https://")
    error_message = "oidc_provider_url must not include the https:// scheme."
  }
}

variable "namespace" {
  description = "Kubernetes namespace of the ServiceAccount allowed to assume the role"
  type        = string
}

variable "service_account" {
  description = "Kubernetes ServiceAccount name allowed to assume the role"
  type        = string
}

variable "policy_json" {
  description = "IAM policy document (JSON) attached to the role"
  type        = string
}

variable "tags" {
  description = "Additional tags merged onto every resource (provider default_tags supply Project/Environment/ManagedBy)"
  type        = map(string)
  default     = {}
}
