# Uses the account's default VPC to stay within Free Tier scope for the demo
# instead of standing up a dedicated VPC/NAT gateway (NAT gateways are not
# free-tier eligible).

data "aws_vpc" "default" {
  default = true
}

# T-068: the app host has no public IPv4 (the EIP is gone; every public IPv4
# bills $3.60/month). It lives in its own subnet of the default VPC, in the
# AZ of its EBS volume, reachable by CloudFront through VPC origins and
# reaching AWS and the internet over IPv6 only (T-067 verified what works that
# way). No NAT gateway and no paid endpoints.
#
# T-018 ruling 1 still holds: the subnet's AZ is var.availability_zone, the
# same variable that sets aws_ebs_volume.mysql_data_v2.availability_zone in
# storage.tf, so the instance and its volume can never land in different AZs.
resource "aws_vpc_ipv6_cidr_block_association" "default" {
  vpc_id                           = data.aws_vpc.default.id
  assign_generated_ipv6_cidr_block = true
}

resource "aws_subnet" "app_private" {
  vpc_id            = data.aws_vpc.default.id
  availability_zone = var.availability_zone

  # A /24 high in the default VPC's /16 (172.31.253.0/24), clear of the
  # default subnets' /20s (172.31.0.0 - 172.31.47.255).
  cidr_block      = cidrsubnet(data.aws_vpc.default.cidr_block, 8, 253)
  ipv6_cidr_block = cidrsubnet(aws_vpc_ipv6_cidr_block_association.default.ipv6_cidr_block, 8, 1)

  map_public_ip_on_launch         = false
  assign_ipv6_address_on_creation = true

  tags = {
    Name    = "${var.project_name}-app-private"
    Project = var.project_name
  }
}

# Outbound over IPv6 only, and nothing may open a connection to the host from
# the internet (an egress-only internet gateway, not an internet gateway
# route). The subnet's route table deliberately has no IPv4 default route.
resource "aws_egress_only_internet_gateway" "app" {
  vpc_id = data.aws_vpc.default.id

  tags = {
    Name    = "${var.project_name}-app"
    Project = var.project_name
  }
}

resource "aws_route_table" "app_private" {
  vpc_id = data.aws_vpc.default.id

  route {
    ipv6_cidr_block        = "::/0"
    egress_only_gateway_id = aws_egress_only_internet_gateway.app.id
  }

  tags = {
    Name    = "${var.project_name}-app-private"
    Project = var.project_name
  }
}

resource "aws_route_table_association" "app_private" {
  subnet_id      = aws_subnet.app_private.id
  route_table_id = aws_route_table.app_private.id
}

# T-068: CloudFront reaches the host through VPC origins, from an AWS-managed
# security group that appears in the VPC once the first VPC origin exists
# (frontend.tf). The two ingress rules below reference it as their ONLY source,
# so the ports answer CloudFront's VPC origins and nothing else (this replaces
# T-022's origin-facing prefix list, which only narrowed the public internet
# down to CloudFront's address ranges; there is no public address any more).
# depends_on defers the lookup to apply time, after the origins exist.
data "aws_security_group" "cloudfront_vpc_origins" {
  name   = "CloudFront-VPCOrigins-Service-SG"
  vpc_id = data.aws_vpc.default.id

  depends_on = [
    aws_cloudfront_vpc_origin.domain_service_api,
    aws_cloudfront_vpc_origin.bff_node,
  ]
}

# T-068: this group and aws_security_group.bff_node are REPLACED here (new
# names), on purpose. Their inline ingress was the CloudFront prefix list, and
# a security group's inline ingress is a Computed attribute: simply deleting the
# blocks leaves the old rules in AWS and Terraform reports no change. A new
# group starts with no rules, and the standalone rules below are all it has.
# The instance is replaced in the same apply, so nothing is attached to the old
# groups when they go. The old description ("... and SSH") is fixed in passing;
# description is ForceNew and a replacement is already happening.
resource "aws_security_group" "domain_service" {
  name        = "${var.project_name}-domain-service-vpc-origin"
  description = "Domain service API (8080), reachable only from CloudFront VPC origins"
  vpc_id      = data.aws_vpc.default.id

  # T-068: no inline ingress. The 8080 rule is the standalone
  # aws_vpc_security_group_ingress_rule.domain_service_api below, because its
  # source (CloudFront's VPC-origin security group) only exists after the VPC
  # origin, which itself needs this group attached to the instance; an inline
  # rule would make that a dependency cycle. (T-022 had scoped this to the
  # CloudFront prefix list; before that it was 0.0.0.0/0.)

  # No SSH ingress: shell access goes through SSM Session Manager, which
  # needs only the instance profile (see iam.tf) and outbound HTTPS.

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
    # T-068: the host reaches AWS, Docker Hub and Cognito over IPv6 only.
    ipv6_cidr_blocks = ["::/0"]
  }

  tags = {
    Project = var.project_name
  }
}

# MySQL is now self-hosted in a container on the domain-service instance
# (localhost, docker `cv` network) rather than RDS, so no dedicated database
# security group is needed — nothing outside the box reaches port 3306.

# T-014 ruling 1: the BFF's port 3000 needs its OWN security group rather than
# a second rule on aws_security_group.domain_service above -- that group
# already carries one reference to the CloudFront origin-facing prefix list,
# and a managed prefix list counts against the 60-rule-per-SG quota as its
# ENTRY COUNT (46 on 2026-08-20), not as one rule. Two references (46 + 46)
# would exceed the quota and fail the apply. Attached to the same instance
# (compute.tf) alongside the existing group.
resource "aws_security_group" "bff_node" {
  name        = "${var.project_name}-bff-node-vpc-origin"
  description = "BFF (3000), reachable only from CloudFront VPC origins"
  vpc_id      = data.aws_vpc.default.id

  # T-068: no inline ingress; see aws_vpc_security_group_ingress_rule.bff_node.

  # No SSH ingress: shell access goes through SSM Session Manager.

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
    # T-068: the host reaches AWS, Docker Hub and Cognito over IPv6 only.
    ipv6_cidr_blocks = ["::/0"]
  }

  tags = {
    Project = var.project_name
  }
}

# T-068: the only ingress to the app host. Source: CloudFront's managed
# VPC-origin security group, nothing else. No CIDR, no prefix list, and the
# host has no public address to receive one anyway. Per-port, per-group so a
# rule's meaning is one line. (The standalone resources are also what avoids
# the instance -> VPC origin -> managed group -> rule -> instance cycle.)
resource "aws_vpc_security_group_ingress_rule" "domain_service_api" {
  security_group_id            = aws_security_group.domain_service.id
  description                  = "Domain service API, reachable only from CloudFront VPC origins (T-068)"
  ip_protocol                  = "tcp"
  from_port                    = 8080
  to_port                      = 8080
  referenced_security_group_id = data.aws_security_group.cloudfront_vpc_origins.id
}

resource "aws_vpc_security_group_ingress_rule" "bff_node" {
  security_group_id            = aws_security_group.bff_node.id
  description                  = "BFF Node app, reachable only from CloudFront VPC origins (T-068)"
  ip_protocol                  = "tcp"
  from_port                    = 3000
  to_port                      = 3000
  referenced_security_group_id = data.aws_security_group.cloudfront_vpc_origins.id
}
