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

  # Review round 1, finding 3: on delete, take a final snapshot rather than
  # dropping the data outright -- cheap insurance (a snapshot of a stopped
  # small volume is negligible against the credit runway) against exactly
  # the class of loss this task exists to prevent.
  final_snapshot = true

  # Cost (recorded against the credit runway, T-012): an 8 GiB gp3 volume in
  # eu-west-3 is on the order of $1/month at AWS list pricing -- negligible
  # against current burn, which is ~$0.68/day (~$21/month) as measured
  # 2026-08-19 with the CI host stopped between builds (T-020; CLAUDE.md
  # carries the full model). This note previously said the figure in
  # CLAUDE.md was stale and needed T-020 -- that has since happened.
  tags = {
    Name    = "${var.project_name}-mysql-data"
    Project = var.project_name
  }

  # Review round 1, finding 3: availability_zone, type, and encrypted are
  # all ForceNew on this resource -- editing var.availability_zone (a knob
  # this task introduces) would otherwise destroy this volume and create an
  # empty replacement, and because the volume id is interpolated into
  # aws_instance.domain_service's user_data, the instance gets replaced in
  # the same apply, so the loss would look like a routine re-provision, not
  # data loss. prevent_destroy makes that apply fail loudly instead.
  # Deliberately remove this only if T-012 ever resolves to a real teardown
  # of this environment -- that should be a decision someone makes on
  # purpose, not a side effect of an unrelated apply.
  lifecycle {
    prevent_destroy = true
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

  # Review round 1, finding 1 -- corrects a wrong assumption in the
  # original comment here. On a user_data-driven replacement, Terraform
  # DOES destroy this attachment before destroying the old instance (the
  # dependency edge from instance_id above is real) -- but "before
  # destroying the instance" does not mean "before the instance is busy".
  # The old instance is still fully running, with XFS mounted and mysqld
  # holding open files, at the moment DetachVolume is issued: EC2 parks a
  # detach of a mounted, busy volume in "detaching" indefinitely, the
  # provider's wait times out, and the apply is left half-done. The
  # dependency edge is what *causes* the detach to be attempted against a
  # live filesystem, not what protects against it.
  #
  # stop_instance_before_detaching = true is the actual fix: it stops the
  # old instance first (cleanly unmounting/flushing), then detaches, then
  # lets the (now-stopped) instance proceed to termination. force_detach is
  # deliberately NOT used instead -- forcing a detach of a still-mounted
  # volume with dirty writeback risks exactly the data loss this task
  # exists to prevent.
  stop_instance_before_detaching = true
}
