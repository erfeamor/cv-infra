# T-004 part 2: the state bucket and lock table the main module's
# backend "s3" block (providers.tf, root module) migrates onto. See
# README.md for the bootstrap/apply/migrate order and the rollback
# procedure -- this file only declares what H1 decided; it does not run
# the migration.

resource "aws_s3_bucket" "tfstate" {
  # Folds in the account id -- see variables.tf's account_id description
  # for why -- so the name is guaranteed globally unique without a
  # network round-trip to check S3's global namespace, which an offline
  # module and a red-first test can't do anyway.
  bucket = "${var.project_name}-tfstate-${var.account_id}"

  # This bucket holds the mapping between every resource in this repo's
  # config and the live AWS objects it created. Losing it by accident
  # (an errant `terraform destroy` run against this module, e.g.) is the
  # exact failure part 2 exists to prevent -- so Terraform itself refuses
  # to destroy it. A deliberate teardown removes this block first.
  lifecycle {
    prevent_destroy = true
  }

  tags = {
    Project = var.project_name
    Purpose = "terraform-state"
  }
}

resource "aws_s3_bucket_versioning" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  versioning_configuration {
    # State corruption (a bad manual edit, a failed apply that half-wrote
    # state) is recoverable with versioning; a truncated local state file
    # was not. This is the whole reason part 2 exists.
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  rule {
    apply_server_side_encryption_by_default {
      # SSE-S3 (AES256), not SSE-KMS: H1 decided the KMS key's per-request
      # cost and key-policy surface aren't justified for a demo-scale
      # state file (a few KB, a handful of writes) -- see part 2 in the
      # task file. Revisit if this bucket ever holds more than Terraform
      # state.
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  # All four explicit and true -- part 2 calls for a public-access block
  # "explicitly, not by default". This bucket holds every secret in
  # every parameter this repo declares SecureString (see the task file's
  # "Why this exists" table); there is no scenario where any of these
  # should be false.
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_policy" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "DenyNonTLS"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:*"
        # Built from the bucket name (var.project_name/var.account_id),
        # not aws_s3_bucket.tfstate.arn: an S3 ARN is always
        # "arn:aws:s3:::<bucket-name>[/key]" -- no account id or region
        # component, so this is exactly the same value the computed .arn
        # would resolve to, but known at plan time. That keeps this
        # resource's `terraform test` coverage at `command = plan`
        # instead of `apply` -- material here because the bucket carries
        # `lifecycle { prevent_destroy = true }`, and test teardown
        # cannot destroy an applied prevent_destroy'd resource.
        Resource = [
          "arn:aws:s3:::${var.project_name}-tfstate-${var.account_id}",
          "arn:aws:s3:::${var.project_name}-tfstate-${var.account_id}/*",
        ]
        Condition = {
          Bool = {
            "aws:SecureTransport" = "false"
          }
        }
      }
    ]
  })

  depends_on = [aws_s3_bucket_public_access_block.tfstate]
}

resource "aws_dynamodb_table" "tf_locks" {
  name = "${var.project_name}-tfstate-lock"

  # PAY_PER_REQUEST: lock writes are one item per plan/apply, negligible
  # against the credit runway (see cv-infra/CLAUDE.md's cost model) --
  # provisioned capacity would need sizing for a workload of a handful of
  # writes a day and buys nothing here.
  billing_mode = "PAY_PER_REQUEST"

  # The S3 backend's dynamodb_table locking protocol hardcodes this
  # attribute name -- it is not a naming convention this module chose.
  hash_key = "LockID"

  attribute {
    name = "LockID"
    type = "S"
  }

  tags = {
    Project = var.project_name
    Purpose = "terraform-state-lock"
  }
}
