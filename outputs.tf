output "domain_service_ecr_repository_url" {
  value = aws_ecr_repository.domain_service.repository_url
}

output "cognito_admin_client_id" {
  value = aws_cognito_user_pool_client.admin_react.id
}

output "frontend_bucket_name" {
  value = aws_s3_bucket.frontend.bucket
}

output "public_site_url" {
  description = "The public site (T-061). cv-public-vanilla at /, cv-admin-react at /admin/."
  value       = "https://${local.public_apex}"
}

output "frontend_cloudfront_domain" {
  value = aws_cloudfront_distribution.frontend.domain_name
}

output "frontend_cloudfront_distribution_id" {
  value = aws_cloudfront_distribution.frontend.id
}

output "cognito_user_pool_id" {
  value = aws_cognito_user_pool.cv.id
}

output "cognito_hosted_ui_domain" {
  # T-062: the custom domain. The prefix domain (aws_cognito_user_pool_domain.cv)
  # is still attached until T-306 moves the admin build.
  value = aws_cognito_user_pool_domain.custom.domain
}

output "public_vanilla_deploy_role_arn" {
  description = "T-045: role the cv-public-vanilla GitHub workflow assumes via OIDC (master only). Not a secret; set it as a GitHub repo variable for T-403."
  value       = aws_iam_role.public_vanilla_deploy.arn
}

output "admin_deploy_role_arn" {
  description = "T-063: role the cv-admin-react GitHub workflow assumes via OIDC (master only, admin/* only). Not a secret; goes in cv-admin-react's repo variable AWS_DEPLOY_ROLE_ARN."
  value       = aws_iam_role.admin_deploy.arn
}
