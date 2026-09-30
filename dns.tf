# T-034 phase 2: a stable DNS name for the CI host, replacing the Elastic IP
# (released in this PR's second commit -- this file's own record below is
# that commit). The human registered erfeamor.com through Route 53 Domains
# on 2026-09-29; the hosted
# zone that came with it (Z0608270B7WND031GVOW) is read here as a DATA
# SOURCE, deliberately NOT imported as a managed resource -- the domain
# registration and the zone's own lifecycle stay outside Terraform (H1).
# Only the one record below is Terraform-managed.
data "aws_route53_zone" "ci" {
  zone_id = "Z0608270B7WND031GVOW"
}

# TTL 60 (short, so a stop/start's new IP propagates quickly) and
# records = [...] deliberately IGNORED after creation: the boot-time updater
# on the CI host itself (scripts/ci-dns-updater.sh, wired up by
# templates/jenkins-provision.sh) keeps this current via UPSERT, every boot,
# because there is no EIP any more (removed in this same commit -- see
# ci.tf's header) -- the public IP is different on every stop/start cycle.
#
# The literal placeholder below is NEVER actually applied to the real
# record past this resource's first creation: `ignore_changes = [records]`
# means Terraform will not touch the live value again regardless of what
# this says, once the resource already exists in state (which it does --
# this second commit only ever runs against a record commit 1 already
# created with a real address). Before the EIP was removed, this read
# aws_eip.drone.public_ip for exactly that first-creation case; now that the
# EIP is gone, there is no real address left to read at plan time, so this
# is a placeholder by necessity as well as by the ignore_changes contract.
#
# Review round 2, finding 5: the placeholder is local.ci_dns_sentinel_ip
# (192.0.2.1, ci-on-demand.tf), NOT a bare "0.0.0.0" -- `allow_overwrite`
# above means a RE-CREATE of this resource (state loss, a deliberate
# `-replace`) applies this literal for real, bypassing ignore_changes
# entirely (that meta-argument only suppresses drift-correction on an
# EXISTING resource, same limitation this module already documents for
# aws_instance.drone). A re-create can therefore only ever set the "host
# not up" sentinel, which the boot-time updater then corrects to the real
# address on the next start -- never a bogus "0.0.0.0" that looks like a
# misconfiguration rather than the deliberate, self-correcting placeholder
# it is.
resource "aws_route53_record" "ci" {
  zone_id = data.aws_route53_zone.ci.zone_id
  name    = var.ci_hostname
  type    = "A"
  ttl     = 60
  records = [local.ci_dns_sentinel_ip] # never applied past creation -- see the comment above

  # Review round 1, finding 4: without this, creating the record fails
  # outright if one already exists at this name/type (e.g. left over from
  # a manual test, or a previous out-of-band change) instead of adopting
  # it -- UPSERT semantics here too, matching the boot updater's own.
  allow_overwrite = true

  lifecycle {
    ignore_changes = [records]
  }
}
