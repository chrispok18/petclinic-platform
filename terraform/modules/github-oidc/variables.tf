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

variable "github_repository_immutable" {
  description = "Optional immutable-ID form of the repository, as owner@<owner_id>/name@<repo_id>. When set, the trust policy accepts this sub form in addition to the plain owner/name form."
  type        = string
  default     = null

  validation {
    condition     = var.github_repository_immutable == null || can(regex("^[A-Za-z0-9_.-]+@[0-9]+/[A-Za-z0-9_.-]+@[0-9]+$", coalesce(var.github_repository_immutable, "x@0/x@0")))
    error_message = "github_repository_immutable must be in owner@<owner_id>/name@<repo_id> form."
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
