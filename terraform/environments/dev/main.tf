locals {
  name_prefix = "${var.project}-${var.environment}"

  common_tags = {
    Project     = var.project
    Environment = var.environment
    ManagedBy   = "terraform"
  }
}

# Module calls (vpc, eks, ecr, rds, secrets) are added by their own stories (E-2 onward).
