terraform {
  required_version = ">= 1.7"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
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
