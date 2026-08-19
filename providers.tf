terraform {
  required_version = ">= 1.7"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    # T-002: null_resource.jenkins_provision (ci.tf) drives the out-of-band
    # SSM provisioning step; local_file stages its rendered script on disk
    # so it can be handed to the AWS CLI without nested-heredoc quoting
    # hazards.
    null = {
      source  = "hashicorp/null"
      version = "~> 3.2"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.4"
    }
    # T-019: zips the on-demand CI Lambda sources (ci-on-demand.tf). Source
    # lives in lambda/ as readable .py rather than a committed binary zip.
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.4"
    }
  }

  # Uncomment once a state bucket exists; local state is fine for the demo.
  # backend "s3" {
  #   bucket = "cv-project-tfstate"
  #   key    = "cv-infra/terraform.tfstate"
  #   region = "eu-west-3"
  # }
}

provider "aws" {
  region = var.aws_region
}
