# T-034 phase 2: a stable DNS name for the CI host, replacing the Elastic IP
# (released in a second, separate commit -- see ci.tf's header). The human
# registered erfeamor.com through Route 53 Domains on 2026-09-29; the hosted
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
# because there is no EIP any more -- the public IP is different on every
# stop/start cycle. The initial value here (the CURRENT EIP, while it still
# exists in this commit) is what makes the FIRST apply create a record that
# already resolves correctly, before the updater has ever run once.
#
# Once the EIP-removal commit lands, aws_eip.drone no longer exists in this
# config at all, so this can no longer read its .public_ip -- at that point
# the value here becomes a harmless placeholder (see that commit's own
# comment on this attribute): ignore_changes means Terraform will never
# again try to push this config value to the real record, no matter what it
# says, once the resource already exists in state.
resource "aws_route53_record" "ci" {
  zone_id = data.aws_route53_zone.ci.zone_id
  name    = var.ci_hostname
  type    = "A"
  ttl     = 60
  records = [aws_eip.drone.public_ip]

  lifecycle {
    ignore_changes = [records]
  }
}
