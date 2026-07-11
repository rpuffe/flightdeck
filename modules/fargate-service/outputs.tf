output "url" {
  description = "Public HTTPS URL the app is served at"
  value       = "https://${local.svc_name}.${var.child_zone_name}"
}

output "service_name" {
  description = "Name of the ECS service"
  value       = aws_ecs_service.app.name
}

output "target_group_arn" {
  description = "ARN of the app's ALB target group"
  value       = aws_lb_target_group.app.arn
}

output "log_group_name" {
  description = "Name of the app's CloudWatch log group"
  value       = aws_cloudwatch_log_group.app.name
}

output "task_role_name" {
  description = "Name of the app's ECS task role (no permissions attached in v1)"
  value       = aws_iam_role.task.name
}
