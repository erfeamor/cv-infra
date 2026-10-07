# T-047: CI deploy from GitHub Actions. No deploy credential lives on the CI
# host (Jenkins/Drone mount docker.sock, so any build is root there; T-005).
# Each service repo's workflow assumes its own OIDC role (the provider is
# aws_iam_openid_connect_provider.github_actions, github-oidc.tf), pushes a
# multi-arch image to its own ECR repo, then runs ITS OWN parameterless SSM
# document, which only runs `cv-redeploy <svc>` on the app host. The role cannot
# send AWS-RunShellScript, the other service's document, or reach the CI host.
#
# The app host is replaced often, so the workflows target it by tag
# (--targets Key=tag:Name,Values=<project>-domain-service) and SendCommand on
# instances is scoped by the ssm:resourceTag/Name condition, not an instance id.
#
# T-049: a third block, the migrate document (cv-redeploy-migrate, runs
# `cv-redeploy migrate`) and the role cv-database's GitHub workflow assumes
# (T-158) to apply production migrations on a master push. Same shape, but it
# pushes no image, so its role has NO ECR access at all.

locals {
  app_host_name_tag = "${var.project_name}-domain-service"
  app_instances_arn = "arn:aws:ec2:${var.aws_region}:${data.aws_caller_identity.current.account_id}:instance/*"
}

# --- domain-service ---

# No `parameters` block on purpose: nothing a caller sends reaches the shell.
resource "aws_ssm_document" "redeploy_domain_service" {
  name            = "cv-redeploy-domain-service"
  document_type   = "Command"
  document_format = "JSON"

  content = jsonencode({
    schemaVersion = "2.2"
    description   = "T-047: run cv-redeploy domain-service on the app host. Takes no parameters."
    mainSteps = [
      {
        action = "aws:runShellScript"
        name   = "redeploy"
        inputs = {
          runCommand     = ["/usr/local/bin/cv-redeploy domain-service"]
          timeoutSeconds = "600"
        }
      }
    ]
  })

  tags = {
    Project = var.project_name
  }
}

resource "aws_iam_role" "domain_service_deploy" {
  name                 = "${var.project_name}-domain-service-deploy"
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
            "token.actions.githubusercontent.com:sub" = "repo:${local.github_org}/cv-domain-service:ref:refs/heads/master"
          }
        }
      }
    ]
  })

  tags = {
    Project = var.project_name
  }
}

resource "aws_iam_role_policy" "domain_service_deploy" {
  name = "ecr-push-and-redeploy"
  role = aws_iam_role.domain_service_deploy.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # ECR requires Resource "*" for GetAuthorizationToken.
        Effect   = "Allow"
        Action   = ["ecr:GetAuthorizationToken"]
        Resource = "*"
      },
      {
        # Own repository only (buildx may read the base manifest/layers).
        Effect = "Allow"
        Action = [
          "ecr:BatchCheckLayerAvailability",
          "ecr:InitiateLayerUpload",
          "ecr:UploadLayerPart",
          "ecr:CompleteLayerUpload",
          "ecr:PutImage",
          "ecr:BatchGetImage",
          "ecr:GetDownloadUrlForLayer",
        ]
        Resource = aws_ecr_repository.domain_service.arn
      },
      {
        # SendCommand authorizes against the document and the instances; the
        # document carries no tags, so it gets its own unconditioned statement.
        Effect   = "Allow"
        Action   = ["ssm:SendCommand"]
        Resource = aws_ssm_document.redeploy_domain_service.arn
      },
      {
        # Instances: only those tagged Name=<app host>, so a replaced host is
        # still reachable but the CI host (a different Name) is not.
        Effect   = "Allow"
        Action   = ["ssm:SendCommand"]
        Resource = local.app_instances_arn
        Condition = {
          StringEquals = { "ssm:resourceTag/Name" = local.app_host_name_tag }
        }
      },
      {
        # These two do not support resource-level permissions.
        Effect   = "Allow"
        Action   = ["ssm:GetCommandInvocation", "ssm:ListCommandInvocations"]
        Resource = "*"
      },
    ]
  })
}

output "domain_service_deploy_role_arn" {
  description = "T-047: role the cv-domain-service GitHub workflow assumes via OIDC (master only). Not a secret; set as a repo variable."
  value       = aws_iam_role.domain_service_deploy.arn
}

output "domain_service_redeploy_document" {
  description = "T-047: SSM document the cv-domain-service workflow sends (target the app host by tag Name=<project>-domain-service)."
  value       = aws_ssm_document.redeploy_domain_service.name
}

# --- bff-node ---

# No `parameters` block on purpose: nothing a caller sends reaches the shell.
resource "aws_ssm_document" "redeploy_bff_node" {
  name            = "cv-redeploy-bff-node"
  document_type   = "Command"
  document_format = "JSON"

  content = jsonencode({
    schemaVersion = "2.2"
    description   = "T-047: run cv-redeploy bff-node on the app host. Takes no parameters."
    mainSteps = [
      {
        action = "aws:runShellScript"
        name   = "redeploy"
        inputs = {
          runCommand     = ["/usr/local/bin/cv-redeploy bff-node"]
          timeoutSeconds = "600"
        }
      }
    ]
  })

  tags = {
    Project = var.project_name
  }
}

resource "aws_iam_role" "bff_node_deploy" {
  name                 = "${var.project_name}-bff-node-deploy"
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
            "token.actions.githubusercontent.com:sub" = "repo:${local.github_org}/cv-bff-node:ref:refs/heads/master"
          }
        }
      }
    ]
  })

  tags = {
    Project = var.project_name
  }
}

resource "aws_iam_role_policy" "bff_node_deploy" {
  name = "ecr-push-and-redeploy"
  role = aws_iam_role.bff_node_deploy.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # ECR requires Resource "*" for GetAuthorizationToken.
        Effect   = "Allow"
        Action   = ["ecr:GetAuthorizationToken"]
        Resource = "*"
      },
      {
        # Own repository only (buildx may read the base manifest/layers).
        Effect = "Allow"
        Action = [
          "ecr:BatchCheckLayerAvailability",
          "ecr:InitiateLayerUpload",
          "ecr:UploadLayerPart",
          "ecr:CompleteLayerUpload",
          "ecr:PutImage",
          "ecr:BatchGetImage",
          "ecr:GetDownloadUrlForLayer",
        ]
        Resource = aws_ecr_repository.bff_node.arn
      },
      {
        # SendCommand authorizes against the document and the instances; the
        # document carries no tags, so it gets its own unconditioned statement.
        Effect   = "Allow"
        Action   = ["ssm:SendCommand"]
        Resource = aws_ssm_document.redeploy_bff_node.arn
      },
      {
        # Instances: only those tagged Name=<app host>, so a replaced host is
        # still reachable but the CI host (a different Name) is not.
        Effect   = "Allow"
        Action   = ["ssm:SendCommand"]
        Resource = local.app_instances_arn
        Condition = {
          StringEquals = { "ssm:resourceTag/Name" = local.app_host_name_tag }
        }
      },
      {
        # These two do not support resource-level permissions.
        Effect   = "Allow"
        Action   = ["ssm:GetCommandInvocation", "ssm:ListCommandInvocations"]
        Resource = "*"
      },
    ]
  })
}

output "bff_node_deploy_role_arn" {
  description = "T-047: role the cv-bff-node GitHub workflow assumes via OIDC (master only). Not a secret; set as a repo variable."
  value       = aws_iam_role.bff_node_deploy.arn
}

output "bff_node_redeploy_document" {
  description = "T-047: SSM document the cv-bff-node workflow sends (target the app host by tag Name=<project>-domain-service)."
  value       = aws_ssm_document.redeploy_bff_node.name
}

# --- database migrate (T-049) ---

# No `parameters` block on purpose: nothing a caller sends reaches the shell.
resource "aws_ssm_document" "redeploy_migrate" {
  name            = "cv-redeploy-migrate"
  document_type   = "Command"
  document_format = "JSON"

  content = jsonencode({
    schemaVersion = "2.2"
    description   = "T-049: run cv-redeploy migrate (Flyway) on the app host. Takes no parameters."
    mainSteps = [
      {
        action = "aws:runShellScript"
        name   = "migrate"
        inputs = {
          runCommand     = ["/usr/local/bin/cv-redeploy migrate"]
          timeoutSeconds = "600"
        }
      }
    ]
  })

  tags = {
    Project = var.project_name
  }
}

resource "aws_iam_role" "database_migrate" {
  name                 = "${var.project_name}-database-migrate"
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
            "token.actions.githubusercontent.com:sub" = "repo:${local.github_org}/cv-database:ref:refs/heads/master"
          }
        }
      }
    ]
  })

  tags = {
    Project = var.project_name
  }
}

# No ECR: the migrate workflow pushes and pulls no image. The two statements
# whose values are known at plan time are a named local (an object, not yet
# JSON) so `terraform test` can assert them; the own-document statement carries
# a computed ARN and stays inline in the policy.
locals {
  database_migrate_known_statements = [
    {
      # Instances: only those tagged Name=<app host>, so a replaced host is
      # still reachable but the CI host (a different Name) is not.
      Effect   = "Allow"
      Action   = ["ssm:SendCommand"]
      Resource = local.app_instances_arn
      Condition = {
        StringEquals = { "ssm:resourceTag/Name" = local.app_host_name_tag }
      }
    },
    {
      # These two do not support resource-level permissions.
      Effect   = "Allow"
      Action   = ["ssm:GetCommandInvocation", "ssm:ListCommandInvocations"]
      Resource = "*"
    },
  ]
}

resource "aws_iam_role_policy" "database_migrate" {
  name = "redeploy-migrate"
  role = aws_iam_role.database_migrate.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat([
      {
        # SendCommand authorizes against the document and the instances; the
        # document carries no tags, so it gets its own unconditioned statement.
        Effect   = "Allow"
        Action   = ["ssm:SendCommand"]
        Resource = aws_ssm_document.redeploy_migrate.arn
      },
    ], local.database_migrate_known_statements)
  })
}

output "database_migrate_role_arn" {
  description = "T-049: role the cv-database GitHub workflow assumes via OIDC (master only). Not a secret; set as the cv-database repo variable AWS_DEPLOY_ROLE_ARN."
  value       = aws_iam_role.database_migrate.arn
}

output "database_migrate_document" {
  description = "T-049: SSM document the cv-database workflow sends (target the app host by tag Name=<project>-domain-service)."
  value       = aws_ssm_document.redeploy_migrate.name
}
