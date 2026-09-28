# Reference values for wiring the main module's backend "s3" block
# (providers.tf, root module). Terraform's `backend` block cannot
# interpolate variables or outputs from another module -- these exist
# for a human to read and copy the literals from, not for automatic
# wiring across the two modules. See README.md for the exact block.

output "state_bucket_name" {
  description = "Copy into the main module's backend \"s3\" block as `bucket`."
  value       = aws_s3_bucket.tfstate.id
}

output "state_bucket_arn" {
  description = "For reference / IAM policies outside this module."
  value       = aws_s3_bucket.tfstate.arn
}

output "lock_table_name" {
  description = "Copy into the main module's backend \"s3\" block as `dynamodb_table`."
  value       = aws_dynamodb_table.tf_locks.name
}
