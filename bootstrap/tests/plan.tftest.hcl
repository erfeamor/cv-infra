# Run with: terraform test (from cv-infra/bootstrap/)
# Mocked AWS provider -- runs offline, no credentials, no network, and
# critically does NOT touch the bootstrap module's own local state or the
# main module's state anywhere else in this repo.
#
# T-004 part 2, H1: versioning, SSE-S3 (AES256, not KMS -- no per-request
# KMS cost or key-policy surface for a demo-scale state file), a
# public-access block with all four flags true, a bucket policy denying
# non-TLS access, and a PAY_PER_REQUEST DynamoDB lock table keyed on
# LockID (the attribute name the S3 backend's dynamodb_table locking
# protocol requires).

mock_provider "aws" {}

variables {
  aws_region   = "eu-west-3"
  project_name = "cv-project"
  account_id   = "760904708057"
}

run "plan_state_bucket" {
  command = plan

  assert {
    condition     = aws_s3_bucket.tfstate.bucket == "cv-project-tfstate-760904708057"
    error_message = "state bucket name must fold in the account id for global uniqueness"
  }
}

run "plan_versioning_enabled" {
  command = plan

  assert {
    condition     = aws_s3_bucket_versioning.tfstate.versioning_configuration[0].status == "Enabled"
    error_message = "state corruption must be recoverable -- versioning has to be Enabled, not Suspended or absent"
  }
}

run "plan_sse_s3" {
  command = plan

  assert {
    # rule is a set block (no addressable index) -- for/if plus anytrue
    # in place of a direct [0] index, same reason as the policy check
    # below.
    condition = anytrue([
      for r in aws_s3_bucket_server_side_encryption_configuration.tfstate.rule :
      anytrue([
        for d in r.apply_server_side_encryption_by_default : d.sse_algorithm == "AES256"
      ])
    ])
    error_message = "H1 decided SSE-S3, not SSE-KMS -- no per-request KMS cost for a demo-scale state file"
  }
}

run "plan_public_access_block" {
  command = plan

  assert {
    condition     = aws_s3_bucket_public_access_block.tfstate.block_public_acls == true
    error_message = "block_public_acls must be explicitly true"
  }

  assert {
    condition     = aws_s3_bucket_public_access_block.tfstate.block_public_policy == true
    error_message = "block_public_policy must be explicitly true"
  }

  assert {
    condition     = aws_s3_bucket_public_access_block.tfstate.ignore_public_acls == true
    error_message = "ignore_public_acls must be explicitly true"
  }

  assert {
    condition     = aws_s3_bucket_public_access_block.tfstate.restrict_public_buckets == true
    error_message = "restrict_public_buckets must be explicitly true"
  }
}

run "plan_deny_non_tls_policy" {
  command = plan

  assert {
    condition = anytrue([
      for stmt in jsondecode(aws_s3_bucket_policy.tfstate.policy).Statement :
      stmt.Effect == "Deny" &&
      tostring(stmt.Condition.Bool["aws:SecureTransport"]) == "false"
    ])
    error_message = "bucket policy must Deny access when aws:SecureTransport is false"
  }
}

run "plan_lock_table" {
  command = plan

  assert {
    condition     = aws_dynamodb_table.tf_locks.billing_mode == "PAY_PER_REQUEST"
    error_message = "lock table must be PAY_PER_REQUEST -- no provisioned capacity to pay for or size"
  }

  assert {
    condition     = aws_dynamodb_table.tf_locks.hash_key == "LockID"
    error_message = "the S3 backend's dynamodb_table locking protocol requires the hash key literally named LockID"
  }
}

# prevent_destroy is a lifecycle meta-argument, not a resource attribute --
# it doesn't appear in plan output for terraform test to assert on directly.
# Verified instead by a static grep in bootstrap's fmt/validate gate (see
# README.md, "Static checks terraform test can't express").
