resource "aws_cloudwatch_log_metric_filter" "alert" {
  for_each = { for a in var.alerts : a.name => a }

  name           = "flightdeck-${local.svc_name}-${each.key}"
  log_group_name = aws_cloudwatch_log_group.app.name
  pattern        = each.value.pattern

  metric_transformation {
    name          = each.key
    namespace     = "flightdeck/${local.svc_name}"
    value         = "1"
    default_value = "0"
  }
}

resource "aws_cloudwatch_metric_alarm" "alert" {
  for_each = aws_cloudwatch_log_metric_filter.alert

  alarm_name          = "flightdeck-${local.svc_name}-${each.key}"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 1
  metric_name         = each.value.metric_transformation[0].name
  namespace           = "flightdeck/${local.svc_name}"
  period              = 300
  statistic           = "Sum"
  threshold           = 1
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.alarm_actions
  ok_actions          = local.alarm_actions
}
