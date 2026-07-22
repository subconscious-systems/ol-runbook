resource "aws_acm_certificate" "workers" {
  count = var.certificate_arn == null ? 1 : 0

  domain_name       = "*.${var.worker_domain}"
  validation_method = "DNS"

  lifecycle {
    create_before_destroy = true
  }

  depends_on = [terraform_data.validated_inputs]
}

locals {
  certificate_validation_options = var.certificate_arn == null ? {
    for option in aws_acm_certificate.workers[0].domain_validation_options :
    option.domain_name => {
      name   = option.resource_record_name
      record = option.resource_record_value
      type   = option.resource_record_type
    }
  } : {}
}

resource "aws_route53_record" "certificate_validation" {
  for_each = local.certificate_validation_options

  zone_id = data.aws_route53_zone.workers.zone_id
  name    = each.value.name
  type    = each.value.type
  ttl     = 60
  records = [each.value.record]
}

resource "aws_acm_certificate_validation" "workers" {
  count = var.certificate_arn == null ? 1 : 0

  certificate_arn = aws_acm_certificate.workers[0].arn
  validation_record_fqdns = [
    for record in aws_route53_record.certificate_validation : record.fqdn
  ]
}

locals {
  effective_certificate_arn = var.certificate_arn != null ? (
    var.certificate_arn
  ) : aws_acm_certificate_validation.workers[0].certificate_arn
}

resource "aws_route53_record" "worker" {
  for_each = var.workers

  zone_id = data.aws_route53_zone.workers.zone_id
  name    = "${each.key}.${var.worker_domain}"
  type    = "A"

  alias {
    name                   = aws_lb.worker[each.key].dns_name
    zone_id                = aws_lb.worker[each.key].zone_id
    evaluate_target_health = true
  }
}
