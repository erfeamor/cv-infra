terraform {
  required_version = ">= 1.7"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  # T-004 part 2: bootstrap/ (its own local state) creates this bucket and
  # table -- see bootstrap/README.md for the apply/migrate order and the
  # rollback procedure. `encrypt = true` is redundant with the bucket's own
  # default SSE-S3 configuration but is set explicitly anyway: it is the
  # backend block's own opt-in, checked by Terraform itself regardless of
  # what the bucket's server-side default happens to be.
  #
  # A literal bucket/table name here, not a variable: backend blocks are
  # evaluated before Terraform has processed variables or state, so they
  # cannot reference either. These two literals must be kept in sync by
  # hand with bootstrap/state-backend.tf's naming (project_name +
  # account_id).
  #
  # Terraform here is pinned to 1.9.8 (see cv-infra/CLAUDE.md); S3-native
  # locking (`use_lockfile`, no DynamoDB table needed) requires >= 1.10.
  # DynamoDB locking is used instead for now -- switch to `use_lockfile`
  # and drop `dynamodb_table` in the same PR that upgrades the toolchain,
  # not as a side effect of an unrelated change.
  backend "s3" {
    bucket         = "cv-project-tfstate-760904708057"
    key            = "cv-infra/terraform.tfstate"
    region         = "eu-west-3"
    encrypt        = true
    dynamodb_table = "cv-project-tfstate-lock"
  }
}

provider "aws" {
  region = var.aws_region
}

# T-061: CloudFront only accepts ACM certificates issued in us-east-1, so the
# certificate and its validation (domain.tf) use this alias. Nothing else does.
provider "aws" {
  alias  = "us_east_1"
  region = "us-east-1"
}
