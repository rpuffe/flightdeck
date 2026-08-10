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

  # Sending is authorized against the identity of the From domain. For dev
  # that identity is Terraform-managed (bootstrap/ses.tf); for prod it is a
  # real domain verified out of band, so this ARN may name an identity that
  # does not exist yet — sends then fail visibly with a clear SES error
  # rather than silently succeeding, which is the behaviour we want.
  mail_identity_domain = element(split("@", local.mail_from), 1)
}

data "aws_iam_policy_document" "email" {
  count = local.email_enabled ? 1 : 0

  statement {
    sid       = "SendAsOwnAddress"
    actions   = ["ses:SendEmail", "ses:SendRawEmail"]
    resources = ["arn:aws:ses:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:identity/${local.mail_identity_domain}"]

    # Narrower than the permissions boundary's equivalent condition, which
    # allows every address the operator authorized for this app. Here it is
    # exactly the one address this environment sends as.
    condition {
      test     = "StringEquals"
      variable = "ses:FromAddress"
      values   = [local.mail_from]
    }
  }
}

resource "aws_iam_policy" "email" {
  count = local.email_enabled ? 1 : 0

  name        = "flightdeck-${local.svc_name}-email"
  description = "Send mail as ${local.mail_from} for ${local.svc_name}"
  policy      = data.aws_iam_policy_document.email[0].json
}

resource "aws_iam_role_policy_attachment" "task_email" {
  count = local.email_enabled ? 1 : 0

  role       = aws_iam_role.task.name
  policy_arn = aws_iam_policy.email[0].arn
}
