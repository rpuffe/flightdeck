# ---------------------------------------------------------------------------
# Manifest-shaped variables: these become app-manifest.yaml fields (spec §6).
# ---------------------------------------------------------------------------

variable "name" {
  description = "App name. DNS-safe, becomes service/log/resource names."
  type        = string

  # "flightdeck-" (11 chars) + name must stay under the 32-char target-group
  # name limit, and dev stacks append "-dev" (4 more chars), so name itself
  # is capped at 16 chars to leave headroom for that suffix.
  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{0,15}$", var.name))
    error_message = "name must be lowercase alphanumeric/hyphens, start with a letter, and be at most 16 characters long (dev stacks append \"-dev\", so this leaves room under the 32-char target-group name limit)."
  }

  validation {
    condition     = var.name != "wake"
    error_message = "'wake' is reserved for the platform scaler endpoint."
  }
}

variable "environment" {
  description = "Deploy environment. \"prod\" resource names are unprefixed (byte-identical to pre-environment stacks); \"dev\" resource names get a \"-dev\" suffix."
  type        = string
  default     = "prod"

  validation {
    condition     = contains(["dev", "prod"], var.environment)
    error_message = "environment must be exactly \"dev\" or \"prod\"."
  }
}

variable "port" {
  description = "Port the container listens on."
  type        = number
}

variable "healthcheck_path" {
  description = "HTTP path the target group health check requests; must return 200 within 30s of container start."
  type        = string
}

variable "cpu" {
  description = "Fargate task CPU units."
  type        = number
}

variable "memory" {
  description = "Fargate task memory (MiB)."
  type        = number
}

variable "env" {
  description = "Non-secret environment variables for the container."
  type        = map(string)
  default     = {}

  validation {
    condition     = !contains(keys(var.env), "STORAGE_BUCKET")
    error_message = "env.STORAGE_BUCKET is reserved — the platform injects it when storage: s3 is set"
  }
}

variable "storage" {
  description = "Optional platform storage the app needs. \"\" (default) = none, no new resources. \"s3\" = a private, per-environment S3 bucket; its name is injected into the container as the STORAGE_BUCKET env var, and the task role gets scoped read/write/list access to it."
  type        = string
  default     = ""

  validation {
    condition     = contains(["", "s3"], var.storage)
    error_message = "storage must be \"\" (no storage, the default) or \"s3\"."
  }
}

# ---------------------------------------------------------------------------
# Deploy-time variable: deliberately NOT a manifest field (spec instructions).
# Supplied by CI (or manually) at apply time, since the image tag changes
# every deploy while the manifest describes the app's shape, not its build.
# ---------------------------------------------------------------------------

variable "image" {
  description = "Full container image reference (e.g. <account>.dkr.ecr.<region>.amazonaws.com/flightdeck/<name>:<tag>)."
  type        = string
}

# ---------------------------------------------------------------------------
# Platform wiring: mirrors bootstrap/edge.tf and bootstrap/platform.tf outputs.
# ---------------------------------------------------------------------------

variable "cluster_arn" {
  description = "ARN of the shared flightdeck ECS cluster."
  type        = string
}

variable "vpc_id" {
  description = "ID of the flightdeck VPC."
  type        = string
}

variable "private_subnet_ids" {
  description = "IDs of the private subnets the service's tasks run in."
  type        = list(string)
}

variable "alb_security_group_id" {
  description = "Security group ID of the shared ALB; the only allowed ingress source for this service's security group."
  type        = string
}

variable "https_listener_arn" {
  description = "ARN of the shared ALB's HTTPS :443 listener to attach this app's host-based rule to."
  type        = string
}

variable "child_zone_name" {
  description = "FQDN of the flightdeck child zone (e.g. fd.robertpuffe.com). The app is served at https://<name>.<child_zone_name>."
  type        = string
}
