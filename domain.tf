# T-061: the project's public domain (erfeamor.com) in front of the existing
# CloudFront distribution. The hosted zone is dns.tf's data source (it stays
# outside Terraform); this file adds the certificate, its DNS validation and
# the alias records.
#
#   erfeamor.com       -> cv-public-vanilla (/) and cv-admin-react (/admin/)
#   www.erfeamor.com   -> 301 to the apex (functions/spa-router.js)
#   react.erfeamor.com -> Vercel (a CNAME, T-410); erfeamor.com/react 301s to it
#   auth.erfeamor.com  -> Cognito's hosted UI and token endpoint (T-062): the
#                         certificate is here, the domain is in auth.tf, and
#                         its alias record is auth_alias below.

locals {
  public_apex = var.public_domain
  public_www  = "www.${var.public_domain}"
  public_auth = "auth.${var.public_domain}"

  # Names on the one certificate. The distribution answers to the first two.
  site_cert_names = [local.public_apex, local.public_www, local.public_auth]
}

# CloudFront reads certificates from us-east-1 only. create_before_destroy
# because a certificate attached to a live distribution can't be destroyed
# first.
resource "aws_acm_certificate" "site" {
  provider = aws.us_east_1

  domain_name               = local.public_apex
  subject_alternative_names = [local.public_www, local.public_auth]
  validation_method         = "DNS"

  lifecycle {
    create_before_destroy = true

    # The records below go in dns.tf's zone, which is a fixed zone ID: a
    # var.public_domain that zone doesn't serve would hang ACM validation.
    precondition {
      condition     = trimsuffix(data.aws_route53_zone.public.name, ".") == var.public_domain
      error_message = "var.public_domain (${var.public_domain}) is not the domain of the Route 53 zone in dns.tf (${data.aws_route53_zone.public.name})."
    }
  }

  tags = {
    Project = var.project_name
  }
}

# One validation CNAME per name. for_each iterates the plan-time-known names
# (the certificate's own domain_validation_options aren't known until apply)
# and looks each one's record up by domain name. ACM always returns one option
# per name; the try() fallbacks only matter under mock_provider, whose apply
# returns an empty set (a real apply with a missing option would fail at ACM
# validation, never create a wrong record).
locals {
  site_cert_options = {
    for o in aws_acm_certificate.site.domain_validation_options : o.domain_name => o
  }
}

resource "aws_route53_record" "site_cert_validation" {
  for_each = toset(local.site_cert_names)

  zone_id         = data.aws_route53_zone.public.zone_id
  name            = try(local.site_cert_options[each.key].resource_record_name, "_pending.${each.key}")
  type            = try(local.site_cert_options[each.key].resource_record_type, "CNAME")
  records         = [try(local.site_cert_options[each.key].resource_record_value, "pending.invalid")]
  ttl             = 60
  allow_overwrite = true
}

# The distribution reads its certificate ARN from THIS resource, so it isn't
# updated until ACM has actually validated the names.
resource "aws_acm_certificate_validation" "site" {
  provider = aws.us_east_1

  certificate_arn         = aws_acm_certificate.site.arn
  validation_record_fqdns = [for r in aws_route53_record.site_cert_validation : r.fqdn]
}

# Alias A and AAAA records for the apex and www (IPv6 is on, frontend.tf).
resource "aws_route53_record" "site_alias" {
  for_each = {
    "apex-A"    = { name = local.public_apex, type = "A" }
    "apex-AAAA" = { name = local.public_apex, type = "AAAA" }
    "www-A"     = { name = local.public_www, type = "A" }
    "www-AAAA"  = { name = local.public_www, type = "AAAA" }
  }

  zone_id         = data.aws_route53_zone.public.zone_id
  name            = each.value.name
  type            = each.value.type
  allow_overwrite = true

  alias {
    name                   = aws_cloudfront_distribution.frontend.domain_name
    zone_id                = aws_cloudfront_distribution.frontend.hosted_zone_id
    evaluate_target_health = false
  }
}

# auth.<apex> -> the CloudFront distribution Cognito creates for its custom
# domain (T-062). Not the site's distribution: Cognito owns this one.
resource "aws_route53_record" "auth_alias" {
  for_each = toset(["A", "AAAA"])

  zone_id = data.aws_route53_zone.public.zone_id
  name    = local.public_auth
  type    = each.key

  alias {
    name                   = aws_cognito_user_pool_domain.custom.cloudfront_distribution
    zone_id                = aws_cognito_user_pool_domain.custom.cloudfront_distribution_zone_id
    evaluate_target_health = false
  }
}

# react.<apex> -> the Vercel project serving cv-public-react (T-410). The target
# is the one Vercel shows in Settings -> Domains for this project.
resource "aws_route53_record" "react" {
  zone_id         = data.aws_route53_zone.public.zone_id
  name            = "react.${var.public_domain}"
  type            = "CNAME"
  ttl             = 300
  records         = [var.react_cname_target]
  allow_overwrite = true
}

# Allowed browser origins for the domain service and the BFF. Read at
# container start through cv_need (templates/domain-service-provision.sh), not
# baked into the script, so adding an origin is a `cv-redeploy`, not a host
# replacement. The cloudfront.net origin stays until T-306 removes it. The
# domain service appends its two localhost dev origins itself.
resource "aws_ssm_parameter" "cors_allowed_origins" {
  name  = "/${var.project_name}/${var.environment}/app/cors-allowed-origins"
  type  = "String"
  value = "https://${local.public_apex},https://${aws_cloudfront_distribution.frontend.domain_name}"

  tags = {
    Project = var.project_name
  }
}
