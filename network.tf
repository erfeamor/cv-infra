# Uses the account's default VPC to stay within Free Tier scope for the demo
# instead of standing up a dedicated VPC/NAT gateway (NAT gateways are not
# free-tier eligible).

data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

# T-018 ruling 1: the domain-service instance now anchors an AZ-locked EBS
# volume (see storage.tf), so its subnet can no longer be picked by list
# position off data.aws_subnets.default -- aws_subnets does not guarantee
# ordering, and a later plan could silently move the instance to a
# different AZ than the volume. Filtered on var.availability_zone so
# compute.tf's subnet_id and storage.tf's aws_ebs_volume.availability_zone
# both trace to that one variable and can never diverge.
data "aws_subnets" "domain_service" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }

  filter {
    name   = "availability-zone"
    values = [var.availability_zone]
  }
}

# T-022: CloudFront's own origin-facing address ranges, published by AWS as a
# managed prefix list and kept current by AWS. Referenced by the 8080 ingress
# below so the domain service answers the edge and nothing else.
#
# This is deliberately the same mechanism T-014 ruling 1 mandates for the BFF's
# port 3000 -- one pattern across both ports, established here first. Read the
# quota note on that ingress before adding a second rule that references it.
data "aws_ec2_managed_prefix_list" "cloudfront_origin_facing" {
  name = "com.amazonaws.global.cloudfront.origin-facing"
}

resource "aws_security_group" "domain_service" {
  name = "${var.project_name}-domain-service"
  # Still says "and SSH" though there is no port-22 ingress and has not been
  # for some time. Left alone deliberately, for the reason spelled out on
  # aws_security_group.drone below: description is ForceNew (AWS has no
  # modify-description API) and this group has no create_before_destroy, so
  # editing this string would destroy a group still attached to
  # aws_instance.domain_service -- DependencyViolation, mid-apply, on the live
  # API box. T-022 deliberately did not touch it (its DoR §3 names this trap).
  # The ingress descriptions below carry the accurate meaning.
  description = "Allows inbound HTTP(S) and SSH to the domain service EC2 instance"
  vpc_id      = data.aws_vpc.default.id

  # T-022: was cidr_blocks = ["0.0.0.0/0"], which made the edge optional --
  # CloudFront is the designed entry point (see frontend.tf), but the origin
  # answered the whole internet on plain HTTP, so any behaviour the
  # distribution enforces could be sidestepped by talking to the EIP. It also
  # served /v3/api-docs unauthenticated (200 with the full springdoc document,
  # while the same path 403s through CloudFront), and that surface grows with
  # every resource M2 lands.
  #
  # Scoped to CloudFront's origin-facing ranges. CloudFront reaches this
  # instance on 8080 over http-only (frontend.tf's domain-service-api origin),
  # so this is the exact set of sources that legitimately arrive here.
  #
  # QUOTA, read before adding another rule that uses this list: an AWS-managed
  # prefix list counts against "inbound rules per security group" (60) as its
  # entry count, not as one rule. This list held 46 entries on 2026-08-20, so
  # ONE reference fits with 14 to spare and TWO (46 + 46 = 92) do not. T-014
  # therefore cannot add a second prefix-list rule for port 3000 to THIS group
  # -- the BFF needs its own security group, which is cleaner anyway.
  ingress {
    description     = "Domain service API, reachable only from the CloudFront origin-facing ranges (T-022)"
    from_port       = 8080
    to_port         = 8080
    protocol        = "tcp"
    prefix_list_ids = [data.aws_ec2_managed_prefix_list.cloudfront_origin_facing.id]
  }

  # No SSH ingress: shell access goes through SSM Session Manager, which
  # needs only the instance profile (see iam.tf) and outbound HTTPS.

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Project = var.project_name
  }
}

resource "aws_security_group" "drone" {
  name = "${var.project_name}-drone"
  # Deliberately still says "Drone CI host" even though Jenkins now sits behind
  # the same rule: aws_security_group.description is ForceNew (AWS has no
  # modify-description API) and this group has no create_before_destroy, so
  # editing this string alone would destroy a group still attached to
  # aws_instance.drone -- DependencyViolation, mid-apply, on a live CI box. The
  # comment below carries the meaning instead. Do not "fix" this wording.
  description = "Allows inbound HTTP(S) from GitHub (webhooks, OAuth callback) to the Drone CI host"
  vpc_id      = data.aws_vpc.default.id

  # T-002: since the reverse proxy went in (templates/jenkins-provision.sh),
  # this single rule fronts both Drone (/) and Jenkins (/jenkins/). No new
  # rule and no new internet-facing port were added for Jenkins -- it is
  # reachable only via the proxy over the internal "drone" docker network,
  # never on its own port.
  ingress {
    description = "Drone + Jenkins web UI / webhooks, via the on-host reverse proxy"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "HTTPS (when TLS is added in front of Drone)"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # No SSH ingress: shell access goes through SSM Session Manager, same as the
  # domain service instance.

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Project = var.project_name
  }
}

# MySQL is now self-hosted in a container on the domain-service instance
# (localhost, docker `cv` network) rather than RDS, so no dedicated database
# security group is needed — nothing outside the box reaches port 3306.
