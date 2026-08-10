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
# for any app listed here; only prod addresses go in the list. Prod domains
# must be verified in SES out of band, with DKIM records added at that
# domain's own registrar.
#
# mail_senders = {
#   studio = ["billing@sephrasmusicstudio.com"]
# }
