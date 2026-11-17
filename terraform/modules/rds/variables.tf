variable "name_prefix" {
  description = "Resource name prefix, petclinic-{env}"
  type        = string
}

variable "subnet_ids" {
  description = "Subnets for the DB subnet group (at least two AZs)"
  type        = list(string)

  validation {
    condition     = length(var.subnet_ids) >= 2
    error_message = "A DB subnet group needs subnets in at least two AZs."
  }
}

variable "security_group_id" {
  description = "RDS security group (3306 from the EKS node SG only)"
  type        = string
}

variable "engine_version" {
  description = "MySQL engine version. \"8.0\" tracks the default 8.0 minor version."
  type        = string
  default     = "8.0"
}

variable "instance_class" {
  description = "RDS instance class"
  type        = string
  default     = "db.t4g.micro"
}

variable "allocated_storage" {
  description = "Allocated storage in GB"
  type        = number
  default     = 20
}

variable "db_name" {
  description = "Initial database name"
  type        = string
  default     = "petclinic"
}

variable "master_username" {
  description = "Master username"
  type        = string
  default     = "petclinic"
}

variable "backup_retention_period" {
  description = "Automated backup retention in days"
  type        = number
  default     = 7
}

variable "apply_immediately" {
  description = "Apply modifications immediately instead of in the maintenance window"
  type        = bool
  default     = false
}

variable "skip_final_snapshot" {
  description = "Skip the final snapshot on destroy"
  type        = bool
  default     = false
}

variable "deletion_protection" {
  description = "Enable RDS deletion protection"
  type        = bool
  default     = true
}

variable "secret_name" {
  description = "Secrets Manager name for the credentials JSON (petclinic/{env}/rds-credentials)"
  type        = string
}

variable "secret_recovery_window_days" {
  description = "Secrets Manager recovery window on delete (0 = immediate, 7-30 = recoverable)"
  type        = number
  default     = 7

  validation {
    condition     = var.secret_recovery_window_days == 0 || (var.secret_recovery_window_days >= 7 && var.secret_recovery_window_days <= 30)
    error_message = "secret_recovery_window_days must be 0 or between 7 and 30."
  }
}

variable "tags" {
  description = "Additional tags merged onto every resource (provider default_tags supply Project/Environment/ManagedBy)"
  type        = map(string)
  default     = {}
}
