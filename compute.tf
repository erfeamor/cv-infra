# Runs cv-domain-service and cv-bff-node (T-014) as containers on the same
# box, plus a self-hosted MySQL 8.4 container -- one instance for the demo
# rather than one EC2 per service. T-035: the app host is a t4g.micro (Graviton,
# arm64), so every image it runs must be multi-arch (amd64 + arm64) on ECR.

# The name pattern must pin the *standard* AL2023 image: a looser
# "al2023-ami-*" also matches the ECS-optimized variant
# (al2023-ami-ecs-hvm-…), which does not run our cloud-init user_data.
#
# This x86_64 lookup is the CI host's (ci.tf). The app host is arm64 and uses
# data.aws_ami.al2023_arm64 below -- do not point either at the other's lookup.
data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-x86_64"]
  }
}

# T-035: the app host's arm64 AL2023 AMI. Same plain-AL2023 name rule (not the
# ECS-optimized variant), plus an explicit architecture filter so the name
# pattern and the architecture can't drift apart. aws_instance.domain_service
# carries a precondition that this AMI's architecture agrees with the
# instance family (t4g/Graviton), so a mismatch fails at plan time.
data "aws_ami" "al2023_arm64" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-arm64"]
  }

  filter {
    name   = "architecture"
    values = ["arm64"]
  }
}

resource "aws_instance" "domain_service" {
  # T-035: arm64 AMI (the CI host keeps the x86 lookup).
  ami           = data.aws_ami.al2023_arm64.id
  instance_type = var.domain_service_instance_type

  # T-035 (and T-005's app-host half): IMDSv2 only, hop limit 1. The host's own
  # param() reads and SSM agent use IMDSv2 from the host; containers on the
  # Docker bridge are a second hop away, so they get no instance credentials
  # (they never call AWS: secrets arrive as env from the host's reads).
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
    # T-068: with no public IPv4 the host's IMDS client may use IPv6.
    http_protocol_ipv6 = "enabled"
  }
  # T-068: the private dual-stack subnet in var.availability_zone (network.tf),
  # the AZ of the EBS volume (T-018 ruling 1). No public IPv4 at all: the
  # EIP is gone; CloudFront reaches the host through VPC origins and the host
  # reaches AWS over IPv6.
  subnet_id                   = aws_subnet.app_private.id
  associate_public_ip_address = false
  ipv6_address_count          = 1
  # T-014 ruling 1: the BFF's port 3000 has its own security group, so both
  # groups attach here.
  vpc_security_group_ids = [aws_security_group.domain_service.id, aws_security_group.bff_node.id]
  iam_instance_profile   = aws_iam_instance_profile.domain_service.name

  # T-044: a small fetch-verify-run stub; the real script is the S3 object in
  # app-host-provision.tf. The stub embeds the script's SHA-256, so editing the
  # script still changes user_data and replaces the host.
  user_data = templatefile("${path.module}/templates/domain-service-bootstrap.sh", {
    aws_region       = var.aws_region
    project_name     = var.project_name
    environment      = var.environment
    artifact_bucket  = aws_s3_bucket.ci_artifacts.id
    artifact_key     = local.app_host_provision_key
    provision_sha256 = local.app_host_provision_sha256
  })

  # A user_data edit changes how the box bootstraps, so it must actually
  # re-provision the instance — without this, a plain `apply` updates user_data
  # in state only and the new bootstrap never runs (AMI churn stays ignored and
  # rebuilt deliberately via -replace, see the lifecycle block below).
  user_data_replace_on_change = true

  # user_data reads these parameters at first boot, so they must exist first.
  #
  # T-068 deliberately leaves out two of them: bff/token-url (it depends on the
  # Cognito domain, which depends on the apex alias record, which depends on
  # the distribution) and app/cors-allowed-origins (it embeds the
  # distribution's domain). The distribution now depends on this instance
  # (VPC origins target its ARN), so listing them would be a cycle. Both
  # exist before any replacement of a running host. A from-scratch account is
  # NOT covered by a one-line recipe (and this is untested): cors_allowed_origins
  # embeds the distribution's domain, so `-target` on it drags in the distribution
  # and the host again. Create both parameters out of band
  # (aws ssm put-parameter) and `terraform import` them before the first apply.
  depends_on = [
    aws_ssm_parameter.db_password,
    aws_ssm_parameter.cognito_issuer_uri,
    aws_ssm_parameter.bff_service_client_id,
    aws_ssm_parameter.bff_service_client_secret,
    aws_ssm_parameter.bff_token_scope,
    # T-044: the stub downloads and verifies these at first boot.
    aws_s3_object.app_host_provision,
    aws_ssm_parameter.app_host_provision_sha256,
    aws_iam_role_policy.app_read_provision_script,
    # T-070: boot reads the migration SQL from S3; without ListBucket a missing
    # key is a 403, not a 404.
    aws_iam_role_policy.app_read_migration_sql,
    # T-054: in non-blocking mode a missing grant silently drops every line.
    aws_iam_role_policy.app_write_container_logs,
  ]

  # Amazon publishes new AL2023 AMIs continually; without this every apply
  # after a release would replace the instance. Rebuild deliberately with
  # `terraform apply -replace=aws_instance.domain_service`. T-035: this is the
  # arm64 AMI; the swap from x86 is exactly such a deliberate -replace.
  lifecycle {
    ignore_changes = [ami]

    # An arm64 AMI needs a Graviton family (letter(s) + digit + "g", e.g.
    # t4g, m7g, c6gd) and vice versa; a mismatch only fails at apply otherwise.
    precondition {
      condition     = data.aws_ami.al2023_arm64.architecture == "arm64" && can(regex("^[a-z]+[0-9]+g[a-z]*\\.", var.domain_service_instance_type))
      error_message = "The app host runs the arm64 AMI, so domain_service_instance_type must be a Graviton family (t4g, m7g, ...); got ${var.domain_service_instance_type}."
    }
  }

  tags = {
    Name    = "${var.project_name}-domain-service"
    Project = var.project_name
  }
}
