resource "aws_route53_zone" "this" {
  count = var.create_route53_zone ? 1 : 0
  name  = var.domain_name
}

locals {
  zone_id = var.create_route53_zone ? aws_route53_zone.this[0].zone_id : var.route53_zone_id
}

resource "terraform_data" "validation" {
  lifecycle {
    precondition {
      condition     = local.zone_id != null
      error_message = "route53_zone_id must be set when create_route53_zone is false."
    }
  }
  input = local.zone_id
}

resource "aws_acm_certificate" "this" {
  domain_name       = var.domain_name
  validation_method = "DNS"

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_route53_record" "validation" {
  for_each = {
    for dvo in aws_acm_certificate.this.domain_validation_options :
    dvo.domain_name => {
      name   = dvo.resource_record_name
      record = dvo.resource_record_value
      type   = dvo.resource_record_type
    }
  }

  zone_id         = local.zone_id
  name            = each.value.name
  type            = each.value.type
  ttl             = 60
  records         = [each.value.record]
  allow_overwrite = true
}

resource "aws_acm_certificate_validation" "this" {
  certificate_arn         = aws_acm_certificate.this.arn
  validation_record_fqdns = [for record in aws_route53_record.validation : record.fqdn]
}
