# -----------------------------------------------------------------------------
# Optional custom domain. Everything here has `count = 0` unless domain_name is
# set, so with the defaults this file creates nothing.
#
# Flow when enabled:
#   1. Register the domain (Route 53 Domains), which also creates a hosted zone.
#   2. Request an HTTPS certificate (ACM). It must live in us-east-1 for CloudFront.
#   3. Prove ownership by writing the DNS records ACM asks for, then wait.
#   4. Point example.com and www.example.com at CloudFront (alias records).
# -----------------------------------------------------------------------------

resource "aws_route53domains_domain" "this" {
  count    = local.use_domain && var.register_domain ? 1 : 0
  provider = aws.us_east_1 # the Route 53 Domains API only exists in us-east-1

  domain_name       = var.domain_name
  duration_in_years = 1
  auto_renew        = true
  transfer_lock     = true

  # Hide your personal data in the public WHOIS database.
  admin_privacy      = true
  registrant_privacy = true
  tech_privacy       = true

  # The same contact for every role. These blocks repeat one shape, so they
  # are good candidates for a dynamic block once you are comfortable with them.
  registrant_contact {
    contact_type   = "PERSON"
    first_name     = var.domain_contact.first_name
    last_name      = var.domain_contact.last_name
    email          = var.domain_contact.email
    phone_number   = var.domain_contact.phone_number
    address_line_1 = var.domain_contact.address_line_1
    city           = var.domain_contact.city
    zip_code       = var.domain_contact.zip_code
    country_code   = var.domain_contact.country_code
  }
  admin_contact {
    contact_type   = "PERSON"
    first_name     = var.domain_contact.first_name
    last_name      = var.domain_contact.last_name
    email          = var.domain_contact.email
    phone_number   = var.domain_contact.phone_number
    address_line_1 = var.domain_contact.address_line_1
    city           = var.domain_contact.city
    zip_code       = var.domain_contact.zip_code
    country_code   = var.domain_contact.country_code
  }
  tech_contact {
    contact_type   = "PERSON"
    first_name     = var.domain_contact.first_name
    last_name      = var.domain_contact.last_name
    email          = var.domain_contact.email
    phone_number   = var.domain_contact.phone_number
    address_line_1 = var.domain_contact.address_line_1
    city           = var.domain_contact.city
    zip_code       = var.domain_contact.zip_code
    country_code   = var.domain_contact.country_code
  }

  # A registered domain is paid for a year. Refuse to destroy it by accident.
  lifecycle {
    prevent_destroy = true
  }
}

# If the domain was registered elsewhere (or earlier), look up its hosted zone.
data "aws_route53_zone" "existing" {
  count = local.use_domain && !var.register_domain ? 1 : 0
  name  = var.domain_name
}

locals {
  zone_id = !local.use_domain ? null : (var.register_domain
    ? aws_route53domains_domain.this[0].hosted_zone_id
  : data.aws_route53_zone.existing[0].zone_id)
}

resource "aws_acm_certificate" "site" {
  count    = local.use_domain ? 1 : 0
  provider = aws.us_east_1

  domain_name               = var.domain_name
  subject_alternative_names = ["www.${var.domain_name}"]
  validation_method         = "DNS"

  # Create the new certificate before deleting the old one when it must be
  # replaced, so the site never runs without a certificate.
  lifecycle {
    create_before_destroy = true
  }
}

# ACM tells us which DNS records prove we own the domain. `for_each` over a
# map built with a `for` expression creates one record per name.
resource "aws_route53_record" "cert_validation" {
  for_each = local.use_domain ? {
    for o in aws_acm_certificate.site[0].domain_validation_options : o.domain_name => o
  } : {}

  zone_id         = local.zone_id
  name            = each.value.resource_record_name
  type            = each.value.resource_record_type
  records         = [each.value.resource_record_value]
  ttl             = 300
  allow_overwrite = true
}

# Not a real AWS object: it makes `apply` wait until the certificate is issued.
resource "aws_acm_certificate_validation" "site" {
  count    = local.use_domain ? 1 : 0
  provider = aws.us_east_1

  certificate_arn         = aws_acm_certificate.site[0].arn
  validation_record_fqdns = [for r in aws_route53_record.cert_validation : r.fqdn]
}

# Alias records are Route 53's way to point a domain at an AWS service.
# A = IPv4, AAAA = IPv6, for both example.com and www.example.com.
resource "aws_route53_record" "site" {
  for_each = local.use_domain ? {
    "apex-a"    = { name = var.domain_name, type = "A" }
    "apex-aaaa" = { name = var.domain_name, type = "AAAA" }
    "www-a"     = { name = "www.${var.domain_name}", type = "A" }
    "www-aaaa"  = { name = "www.${var.domain_name}", type = "AAAA" }
  } : {}

  zone_id = local.zone_id
  name    = each.value.name
  type    = each.value.type

  alias {
    name                   = aws_cloudfront_distribution.this.domain_name
    zone_id                = aws_cloudfront_distribution.this.hosted_zone_id
    evaluate_target_health = false
  }
}
