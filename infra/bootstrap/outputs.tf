# -----------------------------------------------------------------------------
# Outputs are values Terraform prints after `apply` and that other tools can
# read with `terraform output -raw NAME` (the Makefile uses this).
# Docs: https://developer.hashicorp.com/terraform/language/values/outputs
# -----------------------------------------------------------------------------
output "state_bucket" {
  description = "S3 bucket that holds the live stack's state."
  value       = aws_s3_bucket.state.bucket
}

output "aws_region" {
  value = var.aws_region
}

output "plan_role_arn" {
  value = aws_iam_role.plan.arn
}

output "deploy_role_arn" {
  value = aws_iam_role.deploy.arn
}

output "aws_account_id" {
  value = data.aws_caller_identity.current.account_id
}
