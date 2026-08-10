# Outbound mail (optional, off by default).
#
# Everything here is gated on var.mail_senders being non-empty, so an account
# with no mail-sending app creates zero SES resources and zero DNS records —
# the default path is byte-identical to pre-mail bootstrap.
#
# Scope: this file manages the *child zone's* SES identity only
# (fd.robertpuffe.com), which is what dev sends from. Production apps send
# from real domains flightdeck does not own — those identities are verified
# out of band in the SES console, and their DKIM records are added at the
# domain's own registrar. Terraform never touches a zone it doesn't control
# (the same rule edge.tf follows for the parent zone).

locals {
  mail_enabled = length(var.mail_senders) > 0
}

# Domain identity for the flightdeck child zone. Dev traffic sends as
# <app>-dev@<child zone> so test mail can never spend the reputation of a
# production domain — see modules/fargate-service/email.tf for where that
# address is forced.
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

# -all (not ~all): nothing other than SES is ever a legitimate sender for this
# zone, and a hard fail is what keeps a spoofed fd.robertpuffe.com out of
# inboxes.
resource "aws_route53_record" "ses_spf" {
  count = local.mail_enabled ? 1 : 0

  zone_id = aws_route53_zone.child.zone_id
  name    = local.child_zone_name
  type    = "TXT"
  ttl     = 600
  records = ["v=spf1 include:amazonses.com -all"]
}

# p=none is deliberate: DMARC starts in report-only so a misconfigured app
# surfaces in the aggregate reports instead of having its mail silently
# rejected. Tighten to quarantine/reject once the reports are clean.
resource "aws_route53_record" "ses_dmarc" {
  count = local.mail_enabled ? 1 : 0

  zone_id = aws_route53_zone.child.zone_id
  name    = "_dmarc.${local.child_zone_name}"
  type    = "TXT"
  ttl     = 600
  records = ["v=DMARC1; p=none; rua=mailto:${var.alert_email}"]
}

# ---------------------------------------------------------------------------
# Production sending domains hosted in this account
# ---------------------------------------------------------------------------
#
# A production domain is not flightdeck's zone, but when its hosted zone
# happens to live in this account there is no reason to make the operator
# copy DKIM records by hand — Terraform can reach it, so it manages it. A
# domain hosted anywhere else simply stays off mail_managed_zones and gets
# verified through the SES console instead; nothing else about the app
# changes. This is not the edge.tf parent-zone rule being relaxed: that zone
# is off limits because it hosts a live personal site, whereas these are the
# app's own sending domains, listed explicitly by the operator.

# Fails the plan loudly if the zone is not in this account, which is exactly
# the signal the operator needs before an apply half-configures a domain.
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

# Creating this record assumes the apex publishes no SPF today — the variable
# documents that precondition, since Terraform would otherwise overwrite an
# existing policy. -all means SES is the only legitimate sender: adding a
# mailbox provider later (Workspace, Fastmail) requires adding its include:
# here first, or that provider's mail will be rejected.
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
