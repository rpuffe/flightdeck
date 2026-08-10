# Copy to bootstrap.auto.tfvars (gitignored) and fill in.
alert_email = "you@example.com"

# Apps allowed to send mail through SES, and the exact prod From addresses
# each may use. Leave unset (the default) and no app can send: no SES
# resources, no DNS records, and no ses:* in any app's permissions boundary.
#
# This is deliberately operator-controlled and separate from the app's own
# manifest — an app declaring `email:` still cannot send until it is listed
# here. SES reputation and sending quota are account-wide, so granting one app
# affects deliverability for all of them.
#
# The dev address (<app>-dev@fd.robertpuffe.com) is authorized automatically
# for any app listed here; only prod addresses go in the list. Every prod
# domain must be a verified SES identity — either list it in
# mail_managed_zones below and Terraform verifies it, or verify it in the SES
# console and add its DKIM records at whatever registrar holds the domain.
#
# mail_senders = {
#   studio = ["noreply@example.com"]
# }

# Sending domains whose Route53 zone is in THIS account, so Terraform can
# create the SES identity and its DKIM/SPF/DMARC records instead of you
# copying them to a registrar by hand. Domains hosted elsewhere are simply
# left out and verified through the SES console — they work either way.
#
# Terraform writes a TXT record at each apex, so a domain that already
# publishes SPF must stay off this list and be merged manually. The policy
# written is `-all`: SES becomes the only legitimate sender, and adding a
# mailbox provider later means adding its include: here first.
#
# mail_managed_zones = ["example.com"]
