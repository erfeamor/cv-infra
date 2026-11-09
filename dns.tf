# The public hosted zone (registered through Route 53 Domains on 2026-09-29;
# Z0608270B7WND031GVOW) is read here as a DATA SOURCE, deliberately NOT
# imported as a managed resource: the domain registration and the zone's own
# lifecycle stay outside Terraform. domain.tf manages the records in it.
data "aws_route53_zone" "public" {
  zone_id = "Z0608270B7WND031GVOW"
}
