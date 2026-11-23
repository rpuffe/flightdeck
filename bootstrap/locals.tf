data "aws_caller_identity" "current" {}

data "aws_iam_session_context" "current" {
  arn = data.aws_caller_identity.current.arn
}

locals {
  name_prefix = "flightdeck"

  child_zone_name = "${var.subdomain}.${var.parent_zone_name}"

  state_bucket_name = "${local.name_prefix}-tfstate-${data.aws_caller_identity.current.account_id}"
}
