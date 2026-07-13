# Fleet scaler: nightly cool-down + an ALB wake endpoint. Net-new resources
# only (spec 5b). This is the automated counterpart to `make stop`/`make
# start`: the schedule below drives the same desired-count lever those
# targets do, and the wake endpoint lets a visitor bring a stopped app back
# up without shell access.

# ---------------------------------------------------------------------------
# Lambda package
# ---------------------------------------------------------------------------

data "archive_file" "scaler" {
  type        = "zip"
  source_dir  = "${path.module}/lambda"
  output_path = "${path.module}/.terraform/archives/scaler.zip"
}

# ---------------------------------------------------------------------------
# IAM: Lambda execution role
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "scaler_assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "scaler" {
  name               = "${local.name_prefix}-scaler"
  assume_role_policy = data.aws_iam_policy_document.scaler_assume.json
}

data "aws_iam_policy_document" "scaler_permissions" {
  statement {
    sid = "EcsFleetControl"
    actions = [
      "ecs:ListServices",
      "ecs:DescribeServices",
      "ecs:UpdateService",
    ]
    # Same two-ARN-shape pattern as the deploy role (oidc.tf): ListServices
    # is scoped by cluster, DescribeServices/UpdateService by service.
    resources = [
      aws_ecs_cluster.this.arn,
      "arn:aws:ecs:${var.region}:${data.aws_caller_identity.current.account_id}:service/${aws_ecs_cluster.this.name}/*",
    ]
  }

  # Auto-wake "rule flip" (issue #32): the scaler reads listener rules and
  # target health to decide whether an app is ready, and moves a rule's
  # forward action between the app's own target group and the scaler's.
  statement {
    sid = "ElbRuleFlipRead"
    actions = [
      "elasticloadbalancing:DescribeRules",
      "elasticloadbalancing:DescribeTargetGroups",
      "elasticloadbalancing:DescribeTargetHealth",
    ]
    # None of these three actions support resource-level scoping -- AWS
    # requires "*" for Describe* calls on ELBv2. Read-only, so this is a
    # visibility grant, not a mutation risk.
    resources = ["*"]
  }

  statement {
    sid     = "ElbRuleFlipWrite"
    actions = ["elasticloadbalancing:ModifyRule"]
    # Scoped to this ALB's own listener-rule ARN space (same
    # app/flightdeck*/*/*/* shape the deploy role uses in oidc.tf). Caveat:
    # this listener is shared by every app rule AND the scaler's own
    # priority=1 rule, so the grant isn't per-app-isolated -- it covers
    # ModifyRule on any rule under this listener, including the scaler's
    # own (harmless: there's nothing to gain by repointing that rule at
    # itself, but it's not a narrower scope than "any rule flightdeck owns").
    resources = [
      "arn:aws:elasticloadbalancing:${var.region}:${data.aws_caller_identity.current.account_id}:listener-rule/app/${local.name_prefix}*/*/*/*",
    ]
  }

  statement {
    sid = "OwnLogGroup"
    actions = [
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:PutLogEvents",
    ]
    resources = [
      "arn:aws:logs:${var.region}:${data.aws_caller_identity.current.account_id}:log-group:/aws/lambda/${local.name_prefix}-scaler:*",
    ]
  }
}

resource "aws_iam_role_policy" "scaler" {
  name   = "${local.name_prefix}-scaler-permissions"
  role   = aws_iam_role.scaler.id
  policy = data.aws_iam_policy_document.scaler_permissions.json
}

# ---------------------------------------------------------------------------
# Lambda function
# ---------------------------------------------------------------------------

# Explicit log group (matching the fargate-service module's convention) so
# it's created with a bounded retention instead of Lambda auto-creating one
# with no expiry the first time the function runs.
resource "aws_cloudwatch_log_group" "scaler" {
  name              = "/aws/lambda/${local.name_prefix}-scaler"
  retention_in_days = 30
}

resource "aws_lambda_function" "scaler" {
  function_name = "${local.name_prefix}-scaler"
  role          = aws_iam_role.scaler.arn
  handler       = "scaler.lambda_handler"
  runtime       = "python3.13"
  timeout       = 30

  # Blast-radius cap deferred: reserving concurrency requires the account's
  # unreserved pool to stay >= 10, but this account's total concurrency quota
  # is only ~10 (never raised), so any reservation is rejected. The low
  # account-wide ceiling itself bounds concurrent invocations for now; a
  # reserved cap returns once the Lambda concurrency quota is raised. The
  # endpoint is start-only (worst case: fleet warm, bounded by the budget
  # alarm), so this is a hardening gap, not an exposure. Tracked as an issue.
  # reserved_concurrent_executions = 5

  filename         = data.archive_file.scaler.output_path
  source_code_hash = data.archive_file.scaler.output_base64sha256

  environment {
    variables = {
      CLUSTER       = aws_ecs_cluster.this.name
      APP_DOMAIN    = local.child_zone_name
      LISTENER_ARN  = aws_lb_listener.https.arn
      SCALER_TG_ARN = aws_lb_target_group.scaler.arn
    }
  }

  depends_on = [aws_cloudwatch_log_group.scaler]
}

# ---------------------------------------------------------------------------
# Nightly cool-down schedule
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "scheduler_assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["scheduler.amazonaws.com"]
    }

    # Confused-deputy guard. SourceAccount rather than the exact schedule
    # ARN: CreateSchedule validates role assumability BEFORE the schedule
    # exists, so a StringEquals on the schedule's own ARN fails validation
    # (chicken-and-egg, hit during the first apply). SourceAccount still
    # blocks the real threat — cross-account schedules assuming this role —
    # and same-account actors able to create schedules are already trusted.
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
  }
}

resource "aws_iam_role" "scheduler_invoke" {
  name               = "${local.name_prefix}-scaler-invoke"
  assume_role_policy = data.aws_iam_policy_document.scheduler_assume.json
}

data "aws_iam_policy_document" "scheduler_invoke_permissions" {
  statement {
    actions   = ["lambda:InvokeFunction"]
    resources = [aws_lambda_function.scaler.arn]
  }
}

resource "aws_iam_role_policy" "scheduler_invoke" {
  name   = "${local.name_prefix}-scaler-invoke"
  role   = aws_iam_role.scheduler_invoke.id
  policy = data.aws_iam_policy_document.scheduler_invoke_permissions.json
}

# Nightly cool-down: stop every service at 23:30 Central. Deploys and the
# wake endpoint both restore desired_count=1, so this is deliberate
# desired-count drift per the same service-ops convention as `make
# stop-all` (Makefile) -- not a Terraform-owned value.
resource "aws_scheduler_schedule" "nightly_cooldown" {
  name                = "${local.name_prefix}-nightly-cooldown"
  schedule_expression = "cron(30 23 * * ? *)"
  # America/Chicago rather than UTC so the cool-down time doesn't drift
  # across DST changes.
  schedule_expression_timezone = "America/Chicago"

  flexible_time_window {
    mode = "OFF"
  }

  target {
    arn      = aws_lambda_function.scaler.arn
    role_arn = aws_iam_role.scheduler_invoke.arn
    input    = jsonencode({ action = "stop-all" })
  }
}

# ---------------------------------------------------------------------------
# ALB wake endpoint
# ---------------------------------------------------------------------------

resource "aws_lb_target_group" "scaler" {
  name        = "${local.name_prefix}-scaler"
  target_type = "lambda"
}

# ALB must be allowed to invoke the function before it can register as a
# healthy target.
resource "aws_lambda_permission" "alb" {
  statement_id  = "AllowInvokeFromAlb"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.scaler.function_name
  principal     = "elasticloadbalancing.amazonaws.com"
  source_arn    = aws_lb_target_group.scaler.arn
}

# Lets the operator who manages this stack invoke the scaler from `make
# stop/start` (D3, auto-wake). This is a RESOURCE-BASED policy ON the
# flightdeck-owned Lambda -- net-new, §5b-clean -- scoped to this one
# function. It does NOT attach anything to the pre-existing operator IAM
# user (that would modify a resource this stack doesn't own). Same-account:
# a resource-policy grant alone is sufficient to invoke, no identity policy
# on the user required. Authorized for this function specifically (2026-07-12).
resource "aws_lambda_permission" "operator_invoke" {
  statement_id  = "AllowOperatorManualInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.scaler.function_name
  principal     = data.aws_caller_identity.current.arn
}

resource "aws_lb_target_group_attachment" "scaler" {
  target_group_arn = aws_lb_target_group.scaler.arn
  target_id        = aws_lambda_function.scaler.arn

  depends_on = [aws_lambda_permission.alb]
}

# "wake" is a reserved hostname -- app names must not collide with it. The
# wildcard alias in edge.tf already routes *.{child_zone} to this ALB, so
# no DNS changes are needed here; only the listener rule below.
resource "aws_lb_listener_rule" "scaler" {
  listener_arn = aws_lb_listener.https.arn

  # Pinned low so this rule's precedence is deterministic regardless of
  # creation order: app rules (fargate-service module) omit priority and
  # get auto-assigned high numbers, so priority=1 always wins here.
  priority = 1

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.scaler.arn
  }

  condition {
    host_header {
      values = ["wake.${local.child_zone_name}"]
    }
  }
}

# ---------------------------------------------------------------------------
# Operator invoke permission (CHANGE 3, auto-wake review) -- NOT implemented
# ---------------------------------------------------------------------------
#
# `make stop`/`make start`/`make stop-all`/`make start-all` now go through
# this Lambda (D3) instead of calling `aws ecs update-service` directly, so
# the operator principal that runs those targets needs lambda:InvokeFunction
# on aws_lambda_function.scaler. In this account that principal is the IAM
# user "agent-infra-tool" (076047026061) -- a PRE-EXISTING user this stack
# did not create.
#
# Judgment call: NOT adding an aws_iam_user_policy resource attached to that
# user here. Two reasons, either one sufficient on its own:
#   1. Spec 5b / CLAUDE.local.md #2 are unambiguous: "never destroy, modify,
#      or import pre-existing resources; net-new only." Attaching an inline
#      policy to agent-infra-tool is a modification of a resource this stack
#      does not own, not a net-new resource -- the same category of action
#      the safeguard exists to block, even though the intent here is
#      additive/benign.
#   2. Even if that read were wrong, it's unverified whether agent-infra-tool
#      currently holds iam:PutUserPolicy on itself. If it doesn't, this
#      resource would just fail apply; if it does, having an agent apply a
#      policy grant to its own principal is a self-escalation pattern worth
#      a human's eyes first regardless.
#
# Exact policy needed, for Robert to add by hand (e.g. via the console, or a
# small one-off `aws iam put-user-policy` run outside this stack) if `make
# stop`/`make start` fail with AccessDenied on lambda:InvokeFunction:
#
#   Principal: IAM user agent-infra-tool
#   Policy name suggestion: flightdeck-scaler-invoke
#   Policy document:
#     {
#       "Version": "2012-10-17",
#       "Statement": [
#         {
#           "Effect": "Allow",
#           "Action": "lambda:InvokeFunction",
#           "Resource": "<aws_lambda_function.scaler.arn -- see
#                          terraform -chdir=bootstrap output>"
#         }
#       ]
#     }
#
# The Makefile targets detect an invoke failure and print a pointer back to
# this block rather than failing silently or guessing at a fix.

# ---------------------------------------------------------------------------
# Outputs
# ---------------------------------------------------------------------------

output "wake_url" {
  description = "Fleet wake endpoint: lists services and starts any that are stopped"
  value       = "https://wake.${local.child_zone_name}"
}
