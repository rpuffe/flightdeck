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

output "mail_identity_domain" {
  description = "SES domain identity for the flightdeck child zone, or \"\" when no app is authorized to send mail. Dev environments of mail-enabled apps send from <app>-dev@<this domain>."
  value       = local.mail_enabled ? local.child_zone_name : ""
}

output "mail_senders" {
  description = "Map of app name to the prod From addresses its task role is permitted to send as. Mirrors var.mail_senders; the app stack does not read this (its manifest declares the address), but it makes the authorized set visible in bootstrap outputs for audit."
  value       = var.mail_senders
}
