# Worked example: the manifest-driven root config every flightdeck app uses.
# The manifest is the only app-authored infra input; this file is boilerplate
# that never changes per app (spec 5a).

terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }

  # Configured at init time: -backend-config bucket/key/region/use_lockfile.
  # Per-app state key: apps/<name>/terraform.tfstate in the shared bucket.
  backend "s3" {}
}

provider "aws" {
  region = "us-east-1"

  default_tags {
    tags = {
      project    = "flightdeck"
      managed-by = "terraform"
      repo       = "github.com/rpuffe/flightdeck"
    }
  }
}

variable "state_bucket" {
  description = "Shared flightdeck state bucket (holds the bootstrap outputs this stack reads)"
  type        = string
}

variable "image" {
  description = "Full image reference to deploy. Supplied by CI (or manually); deliberately not a manifest field."
  type        = string
  default     = "nginxdemos/hello:latest"
}

data "terraform_remote_state" "bootstrap" {
  backend = "s3"

  config = {
    bucket = var.state_bucket
    key    = "bootstrap/terraform.tfstate"
    region = "us-east-1"
  }
}

locals {
  manifest = yamldecode(file("${path.module}/app-manifest.yaml"))
}

module "app" {
  # Stage 1: local path. Template apps pin a git ref instead (spec 5a).
  source = "../../modules/fargate-service"

  name             = local.manifest.name
  port             = local.manifest.port
  healthcheck_path = local.manifest.healthcheck
  cpu              = local.manifest.cpu
  memory           = local.manifest.memory
  env              = local.manifest.env

  image = var.image

  cluster_arn           = data.terraform_remote_state.bootstrap.outputs.cluster_arn
  vpc_id                = data.terraform_remote_state.bootstrap.outputs.vpc_id
  private_subnet_ids    = data.terraform_remote_state.bootstrap.outputs.private_subnet_ids
  alb_security_group_id = data.terraform_remote_state.bootstrap.outputs.alb_security_group_id
  https_listener_arn    = data.terraform_remote_state.bootstrap.outputs.https_listener_arn
  child_zone_name       = data.terraform_remote_state.bootstrap.outputs.child_zone_name
}

output "url" {
  description = "Where the app is serving"
  value       = module.app.url
}
