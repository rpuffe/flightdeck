# Optional outbound mail via SES (justified by the studio app: monthly
# statements have to reach families, and a downloaded-PDF-plus-manual-send
# loop is the one step of that flow a human still has to do by hand).
#
# Conditional on the email_from opt-in via the count pattern, so the default
# (email_from = "") creates zero resources here and leaves the rendered task
# definition byte-identical to the no-mail path.
#
# This is the second sanctioned exception to "never touch AWS" after storage:
# the app calls SES with the task role's own credentials, no keys to manage.
# The alternative — SES SMTP credentials injected as managed secrets — needs
# no platform support at all and stays available; it trades this IAM grant
# for a long-lived credential the operator has to rotate.

locals {
  email_enabled = var.email_from != ""

  # Dev never sends as the production domain. A staging bounce or a test loop
  # spends SES reputation, and reputation is account-wide — so dev is pinned
  # to the platform zone regardless of what the manifest declares. This is
  # also why the manifest carries no environment keys: the asymmetry lives
  # here, not in the app's contract.
  mail_from = var.environment == "prod" ? var.email_from : "${var.name}-dev@${var.child_zone_name}"

}

# Attach only. The policy is created in bootstrap (oidc.tf), which is what
# lets the app deploy role stay unable to create IAM policies at all — the
# same split storage and managed secrets use. App Terraform can adopt this
# permission but can never write or widen it.
#
# If this attach fails because the policy does not exist, the operator has
# not authorized the app in var.mail_senders. That is a deliberate, legible
# failure at apply time rather than an AccessDenied on the first statement
# a family was supposed to receive.
resource "aws_iam_role_policy_attachment" "task_email" {
  count = local.email_enabled ? 1 : 0

  role       = aws_iam_role.task.name
  policy_arn = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:policy/flightdeck-${local.svc_name}-task-mail"
}
