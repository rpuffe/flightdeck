# Optional log-pattern alerts (spec §6, v0.7.0: the studio app's replication
# sidecar can fail silently while the healthcheck stays green — the error
# lines land in the log group the platform already owns, so the app declares
# which patterns are alert-worthy and the platform watches for them).
# Default ([]) creates zero new resources; existing manifests see an empty
# diff — the established opt-in pattern.

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

# One matching log line within a 5-minute period raises the alarm; actions
# go to the same shared topic as the service alarms (main.tf), so with no
# topic wired in these too are visibility-only.
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
