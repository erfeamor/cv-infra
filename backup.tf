# Nightly logical backup of the self-hosted MySQL container, replacing the
# managed backups RDS used to provide (see CLAUDE.md's "No RDS" decision).
# mysqldump runs on the domain-service EC2 via a systemd timer (see
# templates/domain-service-user-data.sh) and uploads here.

locals {
  # Backup objects live under this single prefix so the IAM policy in
  # iam.tf can scope s3:PutObject to it exactly, rather than the bucket
  # root.
  mysql_backup_prefix = "mysql-dumps"
}

resource "aws_s3_bucket" "backup" {
  bucket = "${var.project_name}-mysql-backup-${var.environment}"

  # Demo project: let terraform destroy remove the bucket even when it
  # holds dumps.
  force_destroy = true

  tags = {
    Project = var.project_name
  }
}

resource "aws_s3_bucket_public_access_block" "backup" {
  bucket = aws_s3_bucket.backup.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# A handful of daily dumps only -- this is credit-funded (T-010), so
# retention stays negligible rather than accumulating indefinitely.
resource "aws_s3_bucket_lifecycle_configuration" "backup" {
  bucket = aws_s3_bucket.backup.id

  rule {
    id     = "expire-old-mysql-dumps"
    status = "Enabled"

    filter {
      prefix = "${local.mysql_backup_prefix}/"
    }

    expiration {
      days = 7
    }

    # Cheap insurance against orphaned multipart parts left over from a
    # crashed upload -- independent of whether the IAM policy below grants
    # s3:AbortMultipartUpload (it doesn't; see the comment in iam.tf).
    abort_incomplete_multipart_upload {
      days_after_initiation = 1
    }
  }
}
