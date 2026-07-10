# Platform primitives: ECS cluster, ECR repo-per-app, budget alarm.
# Net-new resources only (spec 5b) — nothing here imports or adopts.

resource "aws_ecs_cluster" "this" {
  name = local.name_prefix

  setting {
    name = "containerInsights"
    # Disabled: cost-conscious v1; basic CloudWatch alarms come from the fargate-service module instead.
    value = "disabled"
  }
}

resource "aws_ecr_repository" "app" {
  for_each = toset(var.apps)

  name                 = "${local.name_prefix}/${each.key}"
  image_tag_mutability = "IMMUTABLE"

  # Teardown-first platform: `make destroy-bootstrap` must remove repos
  # even when they still contain images.
  force_delete = true

  image_scanning_configuration {
    scan_on_push = true
  }
}

resource "aws_ecr_lifecycle_policy" "app" {
  for_each = aws_ecr_repository.app

  repository = each.value.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Expire untagged images after 7 days"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = 7
        }
        action = {
          type = "expire"
        }
      },
      {
        rulePriority = 2
        description  = "Keep only the last 10 tagged images"
        selection = {
          tagStatus      = "tagged"
          tagPatternList = ["*"]
          countType      = "imageCountMoreThan"
          countNumber    = 10
        }
        action = {
          type = "expire"
        }
      }
    ]
  })
}

# Account-wide by design: tag-scoped budgets require activating the
# `project` cost allocation tag (24h lag + a console step), so v1 watches
# the whole account — acceptable in a near-empty personal account.
resource "aws_budgets_budget" "monthly" {
  name        = "${local.name_prefix}-monthly"
  budget_type = "COST"

  limit_amount = var.budget_limit_usd
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  notification {
    notification_type          = "ACTUAL"
    comparison_operator        = "GREATER_THAN"
    threshold                  = 80
    threshold_type             = "PERCENTAGE"
    subscriber_email_addresses = [var.alert_email]
  }

  notification {
    notification_type          = "FORECASTED"
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    subscriber_email_addresses = [var.alert_email]
  }
}

output "cluster_arn" {
  description = "ARN of the flightdeck ECS cluster"
  value       = aws_ecs_cluster.this.arn
}

output "cluster_name" {
  description = "Name of the flightdeck ECS cluster"
  value       = aws_ecs_cluster.this.name
}

output "ecr_repository_urls" {
  description = "Map of app name => ECR repository URL"
  value       = { for app, repo in aws_ecr_repository.app : app => repo.repository_url }
}
