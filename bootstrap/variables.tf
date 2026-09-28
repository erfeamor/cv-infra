variable "aws_region" {
  description = "Region for the state bucket and lock table. Must match the main module's var.aws_region (providers.tf's backend \"s3\" block) or the migration reads/writes cross-region."
  type        = string
  default     = "eu-west-3"
}

variable "project_name" {
  description = "Prefix for the bucket and table names. Matches the main module's var.project_name default -- this module has no state to migrate, so nothing breaks if the two drift, but keeping them equal is what makes the naming convention (\"<project>-tfstate...\") read the same in both modules."
  type        = string
  default     = "cv-project"
}

variable "account_id" {
  description = <<-EOT
    AWS account id that owns the state bucket, folded into the bucket name
    to guarantee global uniqueness (S3 bucket names are unique across every
    AWS account, not just this one). Hardcoded rather than sourced from
    data.aws_caller_identity: this module's own terraform test runs offline
    against mock_provider, and a data source here would need mocking for no
    benefit -- the account this bootstraps is fixed (see cv-infra/CLAUDE.md,
    "Applied for real to account 760904708057, eu-west-3"), not a value that
    varies per apply.
  EOT
  type        = string
  default     = "760904708057"
}
