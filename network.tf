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

resource "aws_security_group" "domain_service" {
  name        = "${var.project_name}-domain-service"
  description = "Allows inbound HTTP(S) and SSH to the domain service EC2 instance"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description = "App port"
    from_port   = 8080
    to_port     = 8080
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
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
