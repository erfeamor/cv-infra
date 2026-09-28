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
        # Built from aws_s3_bucket.tfstate.bucket (the configured `bucket`
        # argument reflected back), not from repeating the
        # project_name/account_id interpolation a second time, and not
        # from aws_s3_bucket.tfstate.arn: an S3 ARN is always
        # "arn:aws:s3:::<bucket-name>[/key]" -- no account id or region
        # component -- and `.bucket` is an input attribute (known at plan
        # time, equal to the string passed in), unlike `.arn`, which AWS
        # assigns and is unknown until apply. Using `.bucket` here means
        # the name is declared in exactly one place (the resource's own
        # `bucket` argument above) while still keeping this resource's
        # `terraform test` coverage at `command = plan` instead of
        # `apply` -- material because the bucket carries
        # `lifecycle { prevent_destroy = true }`, and test teardown
        # cannot destroy an applied prevent_destroy'd resource.
        Resource = [
          "arn:aws:s3:::${aws_s3_bucket.tfstate.bucket}",
          "arn:aws:s3:::${aws_s3_bucket.tfstate.bucket}/*",
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

resource "aws_s3_bucket_ownership_controls" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  # Review round 1, finding 9: BucketOwnerEnforced disables ACLs for this
  # bucket entirely -- access is bucket-policy-only. The deny-non-TLS
  # policy above already assumes that framing (a Deny statement, not an
  # ACL); a laxer ownership setting would leave an ACL-based path that
  # policy doesn't cover.
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "tfstate" {
  # Review round 2, finding: the previous comment here claimed AWS
  # documents an ordering requirement between ownership controls and
  # lifecycle configuration -- it doesn't, for this rule. Neither
  # noncurrent_version_expiration nor abort_incomplete_multipart_upload
  # touches an ACL, so there is no real dependency to enforce. depends_on
  # is precautionary co-sequencing only, so that a future rule added here
  # that DOES interact with object ownership doesn't silently race
  # BucketOwnerEnforced by accident.
  depends_on = [aws_s3_bucket_ownership_controls.tfstate]

  bucket = aws_s3_bucket.tfstate.id

  rule {
    id     = "state-housekeeping"
    status = "Enabled"

    # Applies to every object in the bucket (there's only ever one, the
    # main module's state file) -- an empty filter, not a prefix, is what
    # makes that explicit rather than implicit.
    filter {}

    # Review round 1, finding 9: versioning without an expiration policy
    # means every historical revision of the state file is kept, and
    # billed, forever. 90 days / a state file this size is negligible
    # against the credit runway (cv-infra/CLAUDE.md's cost model) and
    # comfortably covers "someone notices the corruption and needs to
    # roll back" -- the scenario versioning exists for in the first
    # place (see the "Why this exists" / part 2 rationale). Kept as days,
    # not a version count, because Terraform's S3 backend writes on every
    # apply, not on a fixed schedule -- a version-count limit would give
    # an unpredictable window depending on how often applies happen,
    # where a day count doesn't.
    noncurrent_version_expiration {
      noncurrent_days = 90
    }

    # An interrupted multipart upload's parts are billed indefinitely
    # with nothing to show for them if never aborted. The state file here
    # is a few KB -- nowhere near S3's multipart threshold -- so this
    # rule is precautionary rather than something expected to ever fire,
    # but costs nothing to have in place.
    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
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
