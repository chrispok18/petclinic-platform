output "db_instance_identifier" {
  description = "RDS instance identifier"
  value       = aws_db_instance.this.identifier
}

output "db_instance_arn" {
  description = "RDS instance ARN"
  value       = aws_db_instance.this.arn
}

output "db_address" {
  description = "RDS hostname"
  value       = aws_db_instance.this.address
}

output "db_port" {
  description = "RDS port"
  value       = aws_db_instance.this.port
}

output "db_name" {
  description = "Database name"
  value       = aws_db_instance.this.db_name
}

output "jdbc_url" {
  description = "JDBC URL for the Spring services"
  value       = "jdbc:mysql://${aws_db_instance.this.address}:${aws_db_instance.this.port}/${aws_db_instance.this.db_name}"
}

output "credentials_secret_arn" {
  description = "ARN of the Secrets Manager secret holding the credentials JSON"
  value       = aws_secretsmanager_secret.rds.arn
}

output "credentials_secret_name" {
  description = "Name of the Secrets Manager secret holding the credentials JSON"
  value       = aws_secretsmanager_secret.rds.name
}
