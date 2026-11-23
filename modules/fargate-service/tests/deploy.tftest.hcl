# Plan-time behavior of aws_ecs_service.app. Runs with no AWS access:
# mock_provider supplies every computed value.

mock_provider "aws" {
  mock_data "aws_iam_policy_document" {
    defaults = {
      json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
    }
  }
  mock_data "aws_caller_identity" {
    defaults = {
      account_id = "123456789012"
    }
  }
}

variables {
  name                  = "demo"
  port                  = 8080
  healthcheck_path      = "/healthz"
  cpu                   = 256
  memory                = 512
  image                 = "123456789012.dkr.ecr.us-east-1.amazonaws.com/flightdeck/demo:test"
  cluster_arn           = "arn:aws:ecs:us-east-1:123456789012:cluster/flightdeck"
  vpc_id                = "vpc-0123456789abcdef0"
  subnet_ids            = ["subnet-0123456789abcdef0"]
  alb_security_group_id = "sg-0123456789abcdef0"
  https_listener_arn    = "arn:aws:elasticloadbalancing:us-east-1:123456789012:listener/app/flightdeck/0123456789abcdef/0123456789abcdef"
  child_zone_name       = "fd.example.com"
}

# availability_zone_rebalancing is optional+computed, so an unset (null)
# config is unknown at plan time and cannot be asserted for stateless services.
run "stateless_deploys_rolling_with_spot" {
  command = plan

  assert {
    condition     = aws_ecs_service.app.deployment_maximum_percent == 200
    error_message = "stateless services must deploy at maximum 200%."
  }

  assert {
    condition     = aws_ecs_service.app.deployment_minimum_healthy_percent == 100
    error_message = "stateless services must keep 100% healthy during deploys."
  }


  assert {
    condition     = length(aws_ecs_service.app.capacity_provider_strategy) == 1
    error_message = "the service must use exactly one capacity provider strategy entry."
  }

  assert {
    condition     = one(aws_ecs_service.app.capacity_provider_strategy).capacity_provider == "FARGATE_SPOT"
    error_message = "capacity_provider must default to FARGATE_SPOT."
  }
}

run "stateful_deploys_stop_then_start" {
  command = plan

  variables {
    storage = "s3"
  }

  assert {
    condition     = aws_ecs_service.app.deployment_maximum_percent == 100
    error_message = "stateful services must deploy at maximum 100%."
  }

  assert {
    condition     = aws_ecs_service.app.deployment_minimum_healthy_percent == 0
    error_message = "stateful services must allow 0% healthy during deploys."
  }

  assert {
    condition     = aws_ecs_service.app.availability_zone_rebalancing == "DISABLED"
    error_message = "stateful services must disable AZ rebalancing; ECS rejects 100/0 deploys while it is on."
  }
}

run "retained_storage_is_stateful_too" {
  command = plan

  variables {
    storage = "s3-retained"
  }

  assert {
    condition     = aws_ecs_service.app.deployment_maximum_percent == 100 && aws_ecs_service.app.deployment_minimum_healthy_percent == 0 && aws_ecs_service.app.availability_zone_rebalancing == "DISABLED"
    error_message = "s3-retained must get the same stop-then-start settings as s3."
  }
}

run "on_demand_capacity_provider_is_selectable" {
  command = plan

  variables {
    capacity_provider = "FARGATE"
  }

  assert {
    condition     = one(aws_ecs_service.app.capacity_provider_strategy).capacity_provider == "FARGATE"
    error_message = "capacity_provider = FARGATE must reach the service."
  }
}
