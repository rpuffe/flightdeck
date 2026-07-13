# Edge layer: DNS delegation, wildcard cert, and the shared ALB.
# Per-app listener rules are added later by the fargate-service module;
# the bootstrap ALB only serves the default 404.

# ---------------------------------------------------------------------------
# DNS
# ---------------------------------------------------------------------------

# Parent zone (robertpuffe.com) hosts a live personal site and is
# DATA SOURCE ONLY per spec 5b — never create, modify, or import
# anything in it beyond the single NS delegation record below.
data "aws_route53_zone" "parent" {
  name         = var.parent_zone_name
  private_zone = false
}

# Child zone is fully flightdeck-owned: safe to create and destroy.
resource "aws_route53_zone" "child" {
  name          = local.child_zone_name
  force_destroy = true
}

# The ONLY permitted write to the parent zone (spec 5b): delegate the
# child zone. Everything else in robertpuffe.com is untouchable.
resource "aws_route53_record" "delegation" {
  zone_id = data.aws_route53_zone.parent.zone_id
  name    = local.child_zone_name
  type    = "NS"
  ttl     = 300
  records = aws_route53_zone.child.name_servers
}

# ---------------------------------------------------------------------------
# ACM wildcard certificate
# ---------------------------------------------------------------------------

resource "aws_acm_certificate" "wildcard" {
  domain_name               = "*.${local.child_zone_name}"
  subject_alternative_names = [local.child_zone_name]
  validation_method         = "DNS"

  lifecycle {
    create_before_destroy = true
  }
}

# Validation records live in the child zone, never the parent.
# Keys must be plan-time-known, so key by domain_name; the wildcard and apex
# share one validation record, and allow_overwrite lets both instances UPSERT
# the same name+type instead of conflicting.
resource "aws_route53_record" "cert_validation" {
  for_each = {
    for dvo in aws_acm_certificate.wildcard.domain_validation_options :
    dvo.domain_name => {
      name   = dvo.resource_record_name
      type   = dvo.resource_record_type
      record = dvo.resource_record_value
    }
  }

  allow_overwrite = true

  zone_id = aws_route53_zone.child.zone_id
  name    = each.value.name
  type    = each.value.type
  ttl     = 300
  records = [each.value.record]

  # Delegation must exist before ACM can resolve the validation names.
  depends_on = [aws_route53_record.delegation]
}

resource "aws_acm_certificate_validation" "wildcard" {
  certificate_arn         = aws_acm_certificate.wildcard.arn
  validation_record_fqdns = [for record in aws_route53_record.cert_validation : record.fqdn]
}

# ---------------------------------------------------------------------------
# Shared ALB
# ---------------------------------------------------------------------------

resource "aws_security_group" "alb" {
  name        = "${local.name_prefix}-alb"
  description = "Shared flightdeck ALB: public HTTP/HTTPS in, anywhere out"
  vpc_id      = module.vpc.vpc_id
}

resource "aws_vpc_security_group_ingress_rule" "alb_http" {
  security_group_id = aws_security_group.alb.id
  description       = "Public HTTP (redirects to HTTPS)"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "tcp"
  from_port         = 80
  to_port           = 80
}

resource "aws_vpc_security_group_ingress_rule" "alb_https" {
  security_group_id = aws_security_group.alb.id
  description       = "Public HTTPS"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
}

resource "aws_vpc_security_group_egress_rule" "alb_all" {
  security_group_id = aws_security_group.alb.id
  description       = "Outbound to app targets inside the Flightdeck VPC"
  cidr_ipv4         = module.vpc.vpc_cidr_block
  ip_protocol       = "-1"
}

# Public ingress is the purpose of the shared application load balancer; app
# tasks remain private and accept ingress only from its security group.
#trivy:ignore:AVD-AWS-0053
resource "aws_lb" "main" {
  name                       = local.name_prefix
  internal                   = false
  load_balancer_type         = "application"
  drop_invalid_header_fields = true
  security_groups            = [aws_security_group.alb.id]
  subnets                    = module.vpc.public_subnets
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.main.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type = "redirect"

    redirect {
      port        = "443"
      protocol    = "HTTPS"
      status_code = "HTTP_301"
    }
  }
}

resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.main.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  # Reference the validation resource so the listener waits for issuance.
  certificate_arn = aws_acm_certificate_validation.wildcard.certificate_arn

  default_action {
    type = "fixed-response"

    fixed_response {
      content_type = "text/plain"
      message_body = "flightdeck: no such app"
      status_code  = "404"
    }
  }
}

# One wildcard alias covers every app: host-based listener rules alone
# route each app, so app modules never need Route53 permissions.
resource "aws_route53_record" "wildcard_alias" {
  zone_id = aws_route53_zone.child.zone_id
  name    = "*.${local.child_zone_name}"
  type    = "A"

  alias {
    name                   = aws_lb.main.dns_name
    zone_id                = aws_lb.main.zone_id
    evaluate_target_health = false
  }
}

# ---------------------------------------------------------------------------
# Outputs
# ---------------------------------------------------------------------------

output "child_zone_id" {
  description = "Route53 zone ID of the flightdeck child zone"
  value       = aws_route53_zone.child.zone_id
}

output "child_zone_name" {
  description = "FQDN of the flightdeck child zone"
  value       = local.child_zone_name
}

output "certificate_arn" {
  description = "ARN of the validated wildcard ACM certificate"
  value       = aws_acm_certificate_validation.wildcard.certificate_arn
}

output "alb_arn" {
  description = "ARN of the shared flightdeck ALB"
  value       = aws_lb.main.arn
}

output "alb_dns_name" {
  description = "DNS name of the shared flightdeck ALB"
  value       = aws_lb.main.dns_name
}

output "alb_zone_id" {
  description = "Canonical hosted zone ID of the shared flightdeck ALB"
  value       = aws_lb.main.zone_id
}

output "alb_security_group_id" {
  description = "Security group ID attached to the shared ALB"
  value       = aws_security_group.alb.id
}

output "https_listener_arn" {
  description = "ARN of the HTTPS :443 listener that app listener rules attach to"
  value       = aws_lb_listener.https.arn
}
