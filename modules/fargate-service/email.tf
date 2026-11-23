locals {
  email_enabled = var.email_from != ""

  mail_from = var.environment == "prod" ? var.email_from : "${var.name}-dev@${var.child_zone_name}"

}

resource "aws_iam_role_policy_attachment" "task_email" {
  count = local.email_enabled ? 1 : 0

  role       = aws_iam_role.task.name
  policy_arn = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:policy/flightdeck-${local.svc_name}-task-mail"
}
