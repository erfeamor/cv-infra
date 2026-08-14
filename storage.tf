# T-018: MySQL's data directory used to live on aws_instance.domain_service's
# root volume (templates/domain-service-user-data.sh). compute.tf sets
# user_data_replace_on_change = true, so every user_data edit replaces the
# instance and, until this task, destroyed the database along with it. This
# file gives MySQL a volume whose lifecycle is independent of the instance.

resource "aws_ebs_volume" "mysql_data" {
  # Ruling 1: pinned from the SAME source that selects
  # aws_instance.domain_service's subnet (data.aws_subnets.domain_service in
  # network.tf, filtered on this same variable) -- never computed
  # separately. An EBS volume is AZ-locked, so if the instance and the
  # volume traced to independently-computed AZs, a later plan could move
  # the instance and strand the volume in the wrong zone.
  availability_zone = var.availability_zone

  # Small and cheap on purpose: this holds a test-data MySQL 8.4 instance
  # (see CLAUDE.md's "No RDS" decision), not production volume. gp3 is the
  # default type at this size and doesn't need provisioned IOPS/throughput
  # above the gp3 baseline for this workload.
  size = 8
  type = "gp3"

  # At-rest encryption, no cost or performance impact for gp3 -- no reason
  # not to.
  encrypted = true

  # Cost (recorded against the credit runway, T-010): an 8 GiB gp3 volume in
  # eu-west-3 is on the order of $1/month at AWS list pricing -- negligible
  # against current burn. Burn today is ~$1.23/day (~$37.30/month); the
  # ~$0.92/day (~$28/month) figure still in cv-infra/CLAUDE.md is stale
  # (correcting that file is T-020's job, not this task's).
  tags = {
    Name    = "${var.project_name}-mysql-data"
    Project = var.project_name
  }
}

resource "aws_volume_attachment" "mysql_data" {
  # Ruling 2: device_name is the label Terraform/the EC2 API use for the
  # attachment request -- it is NOT what the guest kernel exposes. These are
  # nitro instances, so the kernel presents this volume as /dev/nvme<N>n1
  # with N unstable across boots. The bootstrap script never uses this
  # value; it resolves the device via
  # /dev/disk/by-id/nvme-Amazon_Elastic_Block_Store_<volume-id-without-hyphen>
  # instead (see templates/domain-service-user-data.sh). This just has to be
  # a syntactically valid, stable /dev/sd* name for the API call.
  device_name = "/dev/sdf"
  volume_id   = aws_ebs_volume.mysql_data.id
  instance_id = aws_instance.domain_service.id

  # force_detach is deliberately NOT set -- flagged as an open question in
  # T-018 rather than decided here. aws_volume_attachment.instance_id
  # referencing aws_instance.domain_service.id already gives Terraform the
  # dependency edge it needs to detach this attachment (old instance) before
  # destroying the old instance itself on a user_data-driven replacement,
  # under the default (non create_before_destroy) ordering already in place
  # -- so the specific "detach hangs while the old instance is still
  # terminating" failure this option guards against shouldn't arise from
  # Terraform's own ordering. Left to the human to confirm via the two live
  # replacements in the acceptance criteria rather than set reflexively: see
  # the implementation report for the full reasoning.
}
