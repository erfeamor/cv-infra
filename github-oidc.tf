# T-045: GitHub Actions -> AWS trust via OIDC, so a GitHub workflow can deploy
# without a long-lived access key (T-005 argued against static deploy keys; the
# old Drone one is deleted, T-064). One provider per account; further roles
# (T-203, the BFF deploy) reuse aws_iam_openid_connect_provider.github_actions.

locals {
  github_org = "erfeamor"
  # The claim GitHub puts in the token's `sub` for a workflow run on master.
  github_public_vanilla_sub = "repo:${local.github_org}/cv-public-vanilla:ref:refs/heads/master"
  github_admin_react_sub    = "repo:${local.github_org}/cv-admin-react:ref:refs/heads/master"
}

# thumbprint_list is deliberately omitted: it is Optional+Computed in the pinned
# provider (5.100.0), and AWS no longer validates this provider's certificate
# chain against a thumbprint (it trusts GitHub's root CAs from its own library).
resource "aws_iam_openid_connect_provider" "github_actions" {
  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]

  tags = {
    Project = var.project_name
  }
}

# Assumable only by cv-public-vanilla workflow runs on master (exact `sub`,
# StringEquals -- no wildcard, so no other repo, branch, PR or environment).
resource "aws_iam_role" "public_vanilla_deploy" {
  name = "${var.project_name}-public-vanilla-deploy"

  # The default, stated so it is asserted: a deploy run is minutes, not hours.
  max_session_duration = 3600

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = { Federated = aws_iam_openid_connect_provider.github_actions.arn }
        Action    = "sts:AssumeRoleWithWebIdentity"
        Condition = {
          StringEquals = {
            "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
            "token.actions.githubusercontent.com:sub" = local.github_public_vanilla_sub
          }
        }
      }
    ]
  })

  tags = {
    Project = var.project_name
  }
}

# The site deploys to the bucket ROOT, where the live admin also lives
# (admin/). The explicit Deny wins over the bucket-wide Allow, so a mis-scoped
# `sync --delete` cannot touch the admin app.
resource "aws_iam_role_policy" "public_vanilla_deploy" {
  name = "frontend-root-deploy"
  role = aws_iam_role.public_vanilla_deploy.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["s3:ListBucket"]
        Resource = aws_s3_bucket.frontend.arn
      },
      {
        Effect   = "Allow"
        Action   = ["s3:PutObject", "s3:DeleteObject"]
        Resource = "${aws_s3_bucket.frontend.arn}/*"
      },
      {
        Effect   = "Deny"
        Action   = ["s3:PutObject", "s3:DeleteObject"]
        Resource = "${aws_s3_bucket.frontend.arn}/admin/*"
      },
      {
        Effect   = "Allow"
        Action   = ["cloudfront:CreateInvalidation"]
        Resource = aws_cloudfront_distribution.frontend.arn
      }
    ]
  })
}

# T-063: the cv-admin-react deploy role, the mirror image of the above. The
# admin app lives under admin/ in the same bucket, so this role may write
# ONLY there (no Deny needed: nothing outside admin/* is ever allowed).
# Replaced Drone's static key (T-008), deleted in T-064.
resource "aws_iam_role" "admin_deploy" {
  name = "${var.project_name}-admin-deploy"

  max_session_duration = 3600

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = { Federated = aws_iam_openid_connect_provider.github_actions.arn }
        Action    = "sts:AssumeRoleWithWebIdentity"
        Condition = {
          StringEquals = {
            "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
            "token.actions.githubusercontent.com:sub" = local.github_admin_react_sub
          }
        }
      }
    ]
  })

  tags = {
    Project = var.project_name
  }
}

# `aws s3 sync dist/ s3://<bucket>/admin/ --delete` lists with prefix `admin/`,
# so ListBucket is limited to that prefix (H1 decision). No GetObject: sync
# uploads need only PutObject.
resource "aws_iam_role_policy" "admin_deploy" {
  name = "frontend-admin-deploy"
  role = aws_iam_role.admin_deploy.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["s3:ListBucket"]
        Resource = aws_s3_bucket.frontend.arn
        Condition = {
          StringLike = {
            "s3:prefix" = ["admin/*", "admin/"]
          }
        }
      },
      {
        Effect   = "Allow"
        Action   = ["s3:PutObject", "s3:DeleteObject"]
        Resource = "${aws_s3_bucket.frontend.arn}/admin/*"
      },
      {
        Effect   = "Allow"
        Action   = ["cloudfront:CreateInvalidation"]
        Resource = aws_cloudfront_distribution.frontend.arn
      }
    ]
  })
}
