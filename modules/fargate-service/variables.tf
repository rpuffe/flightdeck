# ---------------------------------------------------------------------------
# Manifest-shaped variables: these become app-manifest.yaml fields (spec §6).
# ---------------------------------------------------------------------------

variable "name" {
  description = "App name. DNS-safe, becomes service/log/resource names."
  type        = string

  # "flightdeck-" (11 chars) + name must stay under the 32-char target-group
  # name limit, so name itself is capped at 20 chars.
  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{0,19}$", var.name))
    error_message = "name must be lowercase alphanumeric/hyphens, start with a letter, and be at most 20 characters long."
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
