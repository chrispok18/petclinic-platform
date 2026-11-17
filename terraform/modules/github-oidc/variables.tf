variable "create_oidc_provider" {
  description = "Create the account-global token.actions.githubusercontent.com OIDC provider. Set false if it already exists (it is then looked up via data source)."
  type        = bool
  default     = true
}

variable "role_name" {
  description = "Name of the IAM role assumed by GitHub Actions"
  type        = string
  default     = "petclinic-github-actions-role"
}

variable "github_repository" {
  description = "GitHub repository allowed to assume the role, as owner/name"
  type        = string

  validation {
    condition     = can(regex("^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$", var.github_repository))
    error_message = "github_repository must be in owner/name form."
  }
}

variable "allowed_refs" {
  description = "Git refs allowed to assume the role (matched exactly in the OIDC sub claim)"
  type        = list(string)
  default     = ["refs/heads/main"]
}

variable "ecr_repository_arns" {
  description = "ECR repository ARNs the role may push images to"
  type        = list(string)

  validation {
    condition     = length(var.ecr_repository_arns) > 0
    error_message = "At least one ECR repository ARN is required."
  }
}

variable "tags" {
  description = "Additional tags merged onto every resource"
  type        = map(string)
  default     = {}
}
