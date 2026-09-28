# T-004 part 2: this module's job is to create the S3 bucket and DynamoDB
# table the MAIN module's state will live in. It cannot store its own state
# there -- that would be the bucket managing its own existence -- so it
# keeps plain local state (no backend block), gitignored like any other
# local .tfstate. See README.md for the bootstrap/apply/migrate order and
# the rollback procedure.

terraform {
  required_version = ">= 1.7"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region

  # Review round 1, finding 7: this module creates a bucket whose name is
  # itself account-specific (var.account_id, folded into the name in
  # state-backend.tf for global uniqueness -- see variables.tf). Guard
  # against ever applying it against the wrong set of credentials: if the
  # configured credentials resolve to a different account than
  # var.account_id, Terraform refuses before making any AWS call, rather
  # than creating a same-named bucket attempt (which would just fail) or,
  # worse, silently succeeding against an account nobody intended.
  allowed_account_ids = [var.account_id]
}
