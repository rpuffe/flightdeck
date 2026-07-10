data "aws_caller_identity" "current" {}

locals {
  name_prefix = "flightdeck"

  # e.g. fd.robertpuffe.com
  child_zone_name = "${var.subdomain}.${var.parent_zone_name}"

  # Deterministic per-account, never committed anywhere
  state_bucket_name = "${local.name_prefix}-tfstate-${data.aws_caller_identity.current.account_id}"
}
