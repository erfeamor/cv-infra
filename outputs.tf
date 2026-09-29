output "domain_service_public_ip" {
  value = aws_eip.domain_service.public_ip
}

output "domain_service_ecr_repository_url" {
  value = aws_ecr_repository.domain_service.repository_url
}

output "cognito_admin_client_id" {
  value = aws_cognito_user_pool_client.admin_react.id
}

output "frontend_bucket_name" {
  value = aws_s3_bucket.frontend.bucket
}

output "frontend_cloudfront_domain" {
  value = aws_cloudfront_distribution.frontend.domain_name
}

output "drone_server_url" {
  # T-034 phase 2: https, and the stable DNS name (local.ci_public_host,
  # ci-on-demand.tf) instead of the EIP that phase 2's second commit removes.
  value = "https://${local.ci_public_host}"
}

output "frontend_cloudfront_distribution_id" {
  value = aws_cloudfront_distribution.frontend.id
}

output "cognito_user_pool_id" {
  value = aws_cognito_user_pool.cv.id
}

output "cognito_hosted_ui_domain" {
  value = aws_cognito_user_pool_domain.cv.domain
}

output "ci_doorbell_url" {
  description = "T-019: Function URL to register as the GitHub webhook on cv-domain-service, cv-database and cv-admin-react. Until the hooks point here, the automation is inert."
  value       = aws_lambda_function_url.ci_doorbell.function_url
}

# T-008: deliberately NO output for aws_iam_access_key.drone_deploy (its
# .id or .secret). It leaves this module only via the two SecureStrings in
# ssm.tf; `terraform output` / `terraform show` must never be the thing
# that prints it. scripts/check-static.sh enforces that any future
# output referencing that resource is marked sensitive = true.
