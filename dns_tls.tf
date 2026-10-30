data "aws_route53_zone" "this" {
  name         = var.domain_zone
  private_zone = false
}

resource "aws_acm_certificate" "n8n" {
  domain_name       = var.hostname
  validation_method = "DNS"

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_route53_record" "cert_validation" {
  for_each = {
    for o in aws_acm_certificate.n8n.domain_validation_options : o.domain_name => o
  }

  zone_id         = data.aws_route53_zone.this.zone_id
  name            = each.value.resource_record_name
  type            = each.value.resource_record_type
  records         = [each.value.resource_record_value]
  ttl             = 60
  allow_overwrite = true
}

# The DNS-validated certificate above is always requested; it gets issued as soon as the parent
# zone delegates var.domain_zone to Route53. Only in "acm" mode does the listener wait for it.
resource "aws_acm_certificate_validation" "n8n" {
  count                   = var.certificate_mode == "acm" ? 1 : 0
  certificate_arn         = aws_acm_certificate.n8n.arn
  validation_record_fqdns = [for r in aws_route53_record.cert_validation : r.fqdn]

  timeouts {
    create = "20m"
  }
}

moved {
  from = aws_acm_certificate_validation.n8n
  to   = aws_acm_certificate_validation.n8n[0]
}

# Temporary fallback while delegation is missing: self-signed cert imported into ACM so TLS,
# the ALB and the Cognito login work end to end (clients pin the ALB IP via /etc/hosts).
resource "tls_private_key" "fallback" {
  count     = var.certificate_mode == "self_signed" ? 1 : 0
  algorithm = "RSA"
  rsa_bits  = 2048
}

resource "tls_self_signed_cert" "fallback" {
  count                 = var.certificate_mode == "self_signed" ? 1 : 0
  private_key_pem       = tls_private_key.fallback[0].private_key_pem
  dns_names             = [var.hostname]
  validity_period_hours = 24 * 30
  allowed_uses          = ["key_encipherment", "digital_signature", "server_auth"]

  subject {
    common_name  = var.hostname
    organization = "n8n (temporary self-signed)"
  }
}

resource "aws_acm_certificate" "fallback" {
  count            = var.certificate_mode == "self_signed" ? 1 : 0
  private_key      = tls_private_key.fallback[0].private_key_pem
  certificate_body = tls_self_signed_cert.fallback[0].cert_pem

  lifecycle {
    create_before_destroy = true
  }
}

locals {
  listener_certificate_arn = (
    var.certificate_mode == "acm"
    ? aws_acm_certificate_validation.n8n[0].certificate_arn
    : aws_acm_certificate.fallback[0].arn
  )
}

resource "aws_route53_record" "n8n" {
  zone_id = data.aws_route53_zone.this.zone_id
  name    = var.hostname
  type    = "A"

  alias {
    name                   = aws_lb.n8n.dns_name
    zone_id                = aws_lb.n8n.zone_id
    evaluate_target_health = true
  }
}
