locals {
  mail_enabled = length(var.mail_senders) > 0
}

resource "aws_sesv2_email_identity" "child_zone" {
  count = local.mail_enabled ? 1 : 0

  email_identity = local.child_zone_name

  dkim_signing_attributes {
    next_signing_key_length = "RSA_2048_BIT"
  }
}

# Easy DKIM publishes three CNAMEs; AWS rotates the underlying keys behind
# these names, so the records are stable once created.
resource "aws_route53_record" "ses_dkim" {
  count = local.mail_enabled ? 3 : 0

  zone_id = aws_route53_zone.child.zone_id
  name    = "${aws_sesv2_email_identity.child_zone[0].dkim_signing_attributes[0].tokens[count.index]}._domainkey.${local.child_zone_name}"
  type    = "CNAME"
  ttl     = 600
  records = ["${aws_sesv2_email_identity.child_zone[0].dkim_signing_attributes[0].tokens[count.index]}.dkim.amazonses.com"]
}

resource "aws_route53_record" "ses_spf" {
  count = local.mail_enabled ? 1 : 0

  zone_id = aws_route53_zone.child.zone_id
  name    = local.child_zone_name
  type    = "TXT"
  ttl     = 600
  records = ["v=spf1 include:amazonses.com -all"]
}

resource "aws_route53_record" "ses_dmarc" {
  count = local.mail_enabled ? 1 : 0

  zone_id = aws_route53_zone.child.zone_id
  name    = "_dmarc.${local.child_zone_name}"
  type    = "TXT"
  ttl     = 600
  records = ["v=DMARC1; p=none; rua=mailto:${var.alert_email}"]
}

data "aws_route53_zone" "mail" {
  for_each = toset(var.mail_managed_zones)

  name         = "${each.value}."
  private_zone = false
}

resource "aws_sesv2_email_identity" "mail_domain" {
  for_each = toset(var.mail_managed_zones)

  email_identity = each.value

  dkim_signing_attributes {
    next_signing_key_length = "RSA_2048_BIT"
  }
}

# Keyed on domain + slot rather than on the token values, because the tokens
# are unknown until apply and for_each keys have to resolve at plan time.
resource "aws_route53_record" "mail_domain_dkim" {
  for_each = {
    for pair in setproduct(var.mail_managed_zones, [0, 1, 2]) :
    "${pair[0]}-${pair[1]}" => {
      domain = pair[0]
      slot   = pair[1]
    }
  }

  zone_id = data.aws_route53_zone.mail[each.value.domain].zone_id
  name    = "${aws_sesv2_email_identity.mail_domain[each.value.domain].dkim_signing_attributes[0].tokens[each.value.slot]}._domainkey.${each.value.domain}"
  type    = "CNAME"
  ttl     = 600
  records = ["${aws_sesv2_email_identity.mail_domain[each.value.domain].dkim_signing_attributes[0].tokens[each.value.slot]}.dkim.amazonses.com"]
}

resource "aws_route53_record" "mail_domain_spf" {
  for_each = toset(var.mail_managed_zones)

  zone_id = data.aws_route53_zone.mail[each.value].zone_id
  name    = each.value
  type    = "TXT"
  ttl     = 600
  records = ["v=spf1 include:amazonses.com -all"]
}

resource "aws_route53_record" "mail_domain_dmarc" {
  for_each = toset(var.mail_managed_zones)

  zone_id = data.aws_route53_zone.mail[each.value].zone_id
  name    = "_dmarc.${each.value}"
  type    = "TXT"
  ttl     = 600
  records = ["v=DMARC1; p=none; rua=mailto:${var.alert_email}"]
}

output "mail_managed_zones" {
  description = "Sending domains whose SES identity and DNS authentication records are Terraform-managed in this account. Domains sending from flightdeck but absent here are verified out of band."
  value       = var.mail_managed_zones
}

output "mail_identity_domain" {
  description = "SES domain identity for the flightdeck child zone, or \"\" when no app is authorized to send mail. Dev environments of mail-enabled apps send from <app>-dev@<this domain>."
  value       = local.mail_enabled ? local.child_zone_name : ""
}

output "mail_senders" {
  description = "Map of app name to the prod From addresses its task role is permitted to send as. Mirrors var.mail_senders; the app stack does not read this (its manifest declares the address), but it makes the authorized set visible in bootstrap outputs for audit."
  value       = var.mail_senders
}
