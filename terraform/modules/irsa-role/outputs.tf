output "role_arn" {
  description = "IRSA role ARN (eks.amazonaws.com/role-arn ServiceAccount annotation)"
  value       = aws_iam_role.this.arn
}

output "role_name" {
  description = "IRSA role name"
  value       = aws_iam_role.this.name
}

output "policy_arn" {
  description = "ARN of the customer-managed policy attached to the role"
  value       = aws_iam_policy.this.arn
}
