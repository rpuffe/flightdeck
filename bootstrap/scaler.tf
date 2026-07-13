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
      CLUSTER    = aws_ecs_cluster.this.name
      APP_DOMAIN = local.child_zone_name
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
# Outputs
# ---------------------------------------------------------------------------

output "wake_url" {
  description = "Fleet wake endpoint: lists services and starts any that are stopped"
  value       = "https://wake.${local.child_zone_name}"
}
