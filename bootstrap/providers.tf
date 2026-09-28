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
}
