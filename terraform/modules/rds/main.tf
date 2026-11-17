# RDS module (technical-spec: RDS Database, Secrets Management). PETPLAT-22, 23, 25.
# MySQL 8.0, single-AZ, encrypted, reachable only from the EKS node SG (rule lives in the vpc module).
# Master credentials are generated here and stored in Secrets Manager as JSON; ESO syncs them into K8s.

resource "aws_db_subnet_group" "this" {
  name        = "${var.name_prefix}-mysql"
  description = "Subnets for ${var.name_prefix}-mysql"
  subnet_ids  = var.subnet_ids

  tags = merge(var.tags, { Name = "${var.name_prefix}-mysql-subnets" })
}

resource "aws_db_parameter_group" "this" {
  name        = "${var.name_prefix}-mysql80"
  family      = "mysql8.0"
  description = "petclinic MySQL 8.0 - utf8mb4"

  parameter {
    name  = "character_set_server"
    value = "utf8mb4"
  }

  parameter {
    name  = "collation_server"
    value = "utf8mb4_unicode_ci"
  }

  tags = merge(var.tags, { Name = "${var.name_prefix}-mysql80" })

  lifecycle {
    create_before_destroy = true
  }
}

resource "random_password" "master" {
  length           = 24
  special          = true
  override_special = "!#$%^&*()-_=+[]{}<>:?" # RDS forbids / @ " and space
  min_lower        = 2
  min_upper        = 2
  min_numeric      = 2
  min_special      = 2
}

resource "aws_db_instance" "this" {
  identifier = "${var.name_prefix}-mysql"

  engine               = "mysql"
  engine_version       = var.engine_version
  instance_class       = var.instance_class
  parameter_group_name = aws_db_parameter_group.this.name

  db_name  = var.db_name
  username = var.master_username
  password = random_password.master.result
  port     = 3306

  allocated_storage = var.allocated_storage
  # max_allocated_storage left unset: spec caps storage at 20 GB (autoscaling disabled).
  storage_type      = "gp2"
  storage_encrypted = true # AWS-managed aws/rds KMS key

  multi_az               = false
  db_subnet_group_name   = aws_db_subnet_group.this.name
  vpc_security_group_ids = [var.security_group_id]
  publicly_accessible    = false # no public IP even though the subnets are public

  backup_retention_period    = var.backup_retention_period
  copy_tags_to_snapshot      = true
  auto_minor_version_upgrade = true
  apply_immediately          = var.apply_immediately

  skip_final_snapshot = var.skip_final_snapshot
  deletion_protection = var.deletion_protection

  tags = merge(var.tags, { Name = "${var.name_prefix}-mysql" })
}

# --- Credentials secret (PETPLAT-23) ----------------------------------------

resource "aws_secretsmanager_secret" "rds" {
  name        = var.secret_name
  description = "Master credentials for ${var.name_prefix}-mysql (synced to K8s by External Secrets)"
  # 0 = delete immediately on destroy so the name can be reused right away (dev teardown/rebuild).
  recovery_window_in_days = var.secret_recovery_window_days

  tags = merge(var.tags, { Name = var.secret_name })
}

resource "aws_secretsmanager_secret_version" "rds" {
  secret_id = aws_secretsmanager_secret.rds.id
  secret_string = jsonencode({
    username = aws_db_instance.this.username
    password = random_password.master.result
    host     = aws_db_instance.this.address
    port     = aws_db_instance.this.port
    dbname   = aws_db_instance.this.db_name
    engine   = "mysql"
  })
}
