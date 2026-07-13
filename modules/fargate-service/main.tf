# flightdeck-service: one Fargate service behind the shared ALB, driven by
# app-manifest.yaml values (spec §5, §6). Net-new resources only — this
# module never creates Route53 records (the wildcard alias + host-based
# listener rules already route traffic) or ECR repos (bootstrap owns those).

data "aws_region" "current" {}
data "aws_caller_identity" "current" {}

# environment = "prod" is unprefixed so existing prod stacks see an empty
# diff; environment = "dev" gets a "-dev" suffix on every resource name,
# host header, log group, alarm name, and task family below.
locals {
  svc_name = var.environment == "prod" ? var.name : "${var.name}-${var.environment}"

  # Built via merge() with a {}-default branch (never by indexing
  # aws_s3_bucket.data[0] directly), so this tolerates the bucket's
  # count = 0 in the no-storage path and the merge is a no-op: storage = ""
  # (the default) renders a container env byte-identical to pre-v0.4.0,
  # since merge(var.env, {}) has exactly var.env's keys and STORAGE_BUCKET
  # never appears.
  container_env = merge(
    var.env,
    var.storage == "s3" ? { STORAGE_BUCKET = one(aws_s3_bucket.data[*].bucket) } : {}
  )
}

# ---------------------------------------------------------------------------
# Logs
# ---------------------------------------------------------------------------

resource "aws_cloudwatch_log_group" "app" {
  name              = "flightdeck/${local.svc_name}"
  retention_in_days = 30
}

# ---------------------------------------------------------------------------
# IAM
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "ecs_tasks_assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "exec" {
  name                 = "flightdeck-${local.svc_name}-exec"
  assume_role_policy   = data.aws_iam_policy_document.ecs_tasks_assume.json
  permissions_boundary = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:policy/flightdeck-${var.name}-task-boundary"
}

resource "aws_iam_role_policy_attachment" "exec" {
  role       = aws_iam_role.exec.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# Deliberately no permissions attached: v1 apps get no AWS API access at
# all (least privilege). Revisit once the manifest grows secrets/database
# blocks (spec §11 roadmap) that need scoped IAM.
resource "aws_iam_role" "task" {
  name                 = "flightdeck-${local.svc_name}-task"
  assume_role_policy   = data.aws_iam_policy_document.ecs_tasks_assume.json
  permissions_boundary = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:policy/flightdeck-${var.name}-task-boundary"
}

# ---------------------------------------------------------------------------
# Task definition
# ---------------------------------------------------------------------------

resource "aws_ecs_task_definition" "app" {
  family                   = "flightdeck-${local.svc_name}"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = var.cpu
  memory                   = var.memory
  execution_role_arn       = aws_iam_role.exec.arn
  task_role_arn            = aws_iam_role.task.arn

  container_definitions = jsonencode([
    {
      name      = "app"
      image     = var.image
      essential = true

      portMappings = [
        {
          containerPort = var.port
          protocol      = "tcp"
        }
      ]

      # Sorted for plan stability: map iteration order isn't guaranteed,
      # a list built straight from the map would show spurious diffs.
      environment = [
        for k in sort(keys(local.container_env)) : {
          name  = k
          value = local.container_env[k]
        }
      ]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.app.name
          "awslogs-region"        = data.aws_region.current.region
          "awslogs-stream-prefix" = local.svc_name
        }
      }
    }
  ])

  # Register the new immutable revision before deregistering the old one so a
  # failed service update retains an active rollback target.
  lifecycle {
    create_before_destroy = true
  }
}

# ---------------------------------------------------------------------------
# Service security group
# ---------------------------------------------------------------------------

resource "aws_security_group" "service" {
  name        = "flightdeck-${local.svc_name}"
  description = "flightdeck ${local.svc_name}: ALB-only ingress on ${var.port}, anywhere out"
  vpc_id      = var.vpc_id
}

resource "aws_vpc_security_group_ingress_rule" "service" {
  security_group_id            = aws_security_group.service.id
  description                  = "From the shared ALB only"
  referenced_security_group_id = var.alb_security_group_id
  ip_protocol                  = "tcp"
  from_port                    = var.port
  to_port                      = var.port
}

# Documented exception (the app-repo Trivy gate scans this module remotely):
# tasks must reach ECR, CloudWatch Logs, and app dependencies via NAT, and
# AWS-0104 fires on the 0.0.0.0/0 CIDR regardless of port scoping.
# Compensating controls: private subnets, ALB-only ingress, permissionless
# task role. Egress lockdown (VPC endpoints + explicit CIDRs) is roadmap work.
#trivy:ignore:aws-0104
resource "aws_vpc_security_group_egress_rule" "service" {
  security_group_id = aws_security_group.service.id
  description       = "All outbound"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

# ---------------------------------------------------------------------------
# Target group + listener rule
# ---------------------------------------------------------------------------

resource "aws_lb_target_group" "app" {
  name        = "flightdeck-${local.svc_name}"
  port        = var.port
  protocol    = "HTTP"
  target_type = "ip"
  vpc_id      = var.vpc_id

  health_check {
    path                = var.healthcheck_path
    matcher             = "200"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }

  # Short on purpose: this is a demo platform, not a high-traffic prod
  # service, so fast redeploy/teardown wins over connection draining.
  deregistration_delay = 30
}

resource "aws_lb_listener_rule" "app" {
  listener_arn = var.https_listener_arn

  # Priority omitted: AWS auto-assigns the next free slot, so independently
  # deployed app stacks never need to coordinate priorities with each other.
  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app.arn
  }

  condition {
    host_header {
      values = ["${local.svc_name}.${var.child_zone_name}"]
    }
  }
}

# ---------------------------------------------------------------------------
# ECS service
# ---------------------------------------------------------------------------

resource "aws_ecs_service" "app" {
  name            = local.svc_name
  cluster         = var.cluster_arn
  task_definition = aws_ecs_task_definition.app.arn
  desired_count   = 1
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = var.private_subnet_ids
    security_groups  = [aws_security_group.service.id]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.app.arn
    container_name   = "app"
    container_port   = var.port
  }

  # Manifest contract: healthy within 30s of start (spec §6).
  health_check_grace_period_seconds = 30

  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  # A target group must be attached to a listener before a service can
  # register targets against it.
  depends_on = [aws_lb_listener_rule.app]
}

# ---------------------------------------------------------------------------
# Alarms (v1 has no SNS topic, so these have no actions — visibility only)
# ---------------------------------------------------------------------------

resource "aws_cloudwatch_metric_alarm" "cpu_high" {
  alarm_name          = "flightdeck-${local.svc_name}-cpu-high"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "CPUUtilization"
  namespace           = "AWS/ECS"
  period              = 300
  statistic           = "Average"
  threshold           = 80
  treat_missing_data  = "notBreaching"

  dimensions = {
    ClusterName = element(split("/", var.cluster_arn), 1)
    ServiceName = aws_ecs_service.app.name
  }
}

resource "aws_cloudwatch_metric_alarm" "unhealthy_hosts" {
  alarm_name          = "flightdeck-${local.svc_name}-unhealthy-hosts"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 1
  metric_name         = "UnHealthyHostCount"
  namespace           = "AWS/ApplicationELB"
  period              = 60
  statistic           = "Maximum"
  threshold           = 1
  treat_missing_data  = "notBreaching"

  dimensions = {
    # No standalone ALB ARN input exists; the load balancer's ARN suffix
    # (app/<lb-name>/<lb-id>) is embedded in the listener ARN we already have.
    LoadBalancer = join("/", slice(split("/", var.https_listener_arn), 1, 4))
    TargetGroup  = aws_lb_target_group.app.arn_suffix
  }
}
