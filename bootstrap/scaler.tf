data "archive_file" "scaler" {
  type        = "zip"
  source_dir  = "${path.module}/lambda"
  output_path = "${path.module}/.terraform/archives/scaler.zip"
  excludes    = ["__pycache__"]
}

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
    resources = [
      aws_ecs_cluster.this.arn,
      "arn:aws:ecs:${var.region}:${data.aws_caller_identity.current.account_id}:service/${aws_ecs_cluster.this.name}/*",
    ]
  }

  statement {
    sid       = "EcsTaskAgeRead"
    actions   = ["ecs:ListTasks"]
    resources = ["*"]
    condition {
      test     = "ArnEquals"
      variable = "ecs:cluster"
      values   = [aws_ecs_cluster.this.arn]
    }
  }
  # Same two-ARN-shape pattern as the deploy role (oidc.tf): ListServices
  # is scoped by cluster, DescribeServices/UpdateService by service.

  statement {
    sid     = "EcsTaskDescribe"
    actions = ["ecs:DescribeTasks"]
    resources = [
      "arn:aws:ecs:${var.region}:${data.aws_caller_identity.current.account_id}:task/${aws_ecs_cluster.this.name}/*",
    ]
  }

  statement {
    sid = "ElbTargetHealthRead"
    actions = [
      "elasticloadbalancing:DescribeTargetGroups",
      "elasticloadbalancing:DescribeTargetHealth",
      "cloudwatch:GetMetricData",
    ]
    # None of these actions supports resource-level permissions.
    resources = ["*"]
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

# Explicit so it has a bounded retention. Lambda would otherwise create
# /aws/lambda/<name> on first invoke with no retention set.
resource "aws_cloudwatch_log_group" "scaler" {
  name              = "/aws/lambda/${local.name_prefix}-scaler"
  retention_in_days = 30
}

resource "aws_cloudwatch_log_metric_filter" "scaler_action_errors" {
  name           = "${local.name_prefix}-scaler-action-errors"
  log_group_name = aws_cloudwatch_log_group.scaler.name
  pattern        = "{ $.event_type = \"action_result\" && $.status = \"error\" }"

  metric_transformation {
    name      = "ActionErrors"
    namespace = "Flightdeck/Scaler"
    value     = "1"
  }
}

resource "aws_lambda_function" "scaler" {
  function_name = "${local.name_prefix}-scaler"
  role          = aws_iam_role.scaler.arn
  handler       = "scaler.lambda_handler"
  runtime       = "python3.13"
  timeout       = 30

  filename         = data.archive_file.scaler.output_path
  source_code_hash = data.archive_file.scaler.output_base64sha256

  environment {
    variables = {
      CLUSTER            = aws_ecs_cluster.this.name
      APP_DOMAIN         = local.child_zone_name
      IDLE_SLEEP_MINUTES = tostring(var.idle_sleep_minutes)
    }
  }

  depends_on = [aws_cloudwatch_log_group.scaler]
}

data "aws_iam_policy_document" "scheduler_assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["scheduler.amazonaws.com"]
    }

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

resource "aws_scheduler_schedule" "nightly_cooldown" {
  name                = "${local.name_prefix}-nightly-cooldown"
  schedule_expression = "cron(30 23 * * ? *)"

  schedule_expression_timezone = "America/Chicago"

  flexible_time_window {
    mode = "OFF"
  }

  target {
    arn      = aws_lambda_function.scaler.arn
    role_arn = aws_iam_role.scheduler_invoke.arn
    input    = jsonencode({ action = "stop-all" })
  }
  # Confused-deputy guard. SourceAccount rather than the exact schedule
  # ARN: CreateSchedule validates role assumability BEFORE the schedule
  # exists, so a StringEquals on the schedule's own ARN fails validation
  # (chicken-and-egg, hit during the first apply). SourceAccount still
  # blocks the real threat — cross-account schedules assuming this role —
  # and same-account actors able to create schedules are already trusted.
}

resource "aws_scheduler_schedule" "idle_sleep" {
  count = var.idle_sleep_minutes > 0 ? 1 : 0

  name                = "${local.name_prefix}-idle-sleep"
  schedule_expression = "rate(10 minutes)"

  flexible_time_window {
    mode = "OFF"
  }

  target {
    arn      = aws_lambda_function.scaler.arn
    role_arn = aws_iam_role.scheduler_invoke.arn
    input    = jsonencode({ action = "sleep-idle" })
  }
}

resource "aws_scheduler_schedule" "morning_warmup" {
  count = length(var.morning_warmup_services) > 0 ? 1 : 0

  name                         = "${local.name_prefix}-morning-warmup"
  schedule_expression          = "cron(0 7 * * ? *)"
  schedule_expression_timezone = "America/Chicago"

  flexible_time_window {
    mode = "OFF"
  }

  target {
    arn      = aws_lambda_function.scaler.arn
    role_arn = aws_iam_role.scheduler_invoke.arn
    input = jsonencode({
      action   = "start"
      services = var.morning_warmup_services
    })
  }
}

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

# Same-account principal: this resource-based grant alone authorizes the
# invoke, so nothing is attached to the operator's IAM identity.
resource "aws_lambda_permission" "operator_invoke" {
  statement_id  = "AllowOperatorManualInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.scaler.function_name
  principal     = data.aws_iam_session_context.current.issuer_arn
}

resource "aws_lb_target_group_attachment" "scaler" {
  target_group_arn = aws_lb_target_group.scaler.arn
  target_id        = aws_lambda_function.scaler.arn

  depends_on = [aws_lambda_permission.alb]
}

resource "aws_lb_listener_rule" "scaler" {
  listener_arn = aws_lb_listener.https.arn

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

output "wake_url" {
  description = "Fleet wake endpoint: lists services and starts any that are stopped"
  value       = "https://wake.${local.child_zone_name}"
}
