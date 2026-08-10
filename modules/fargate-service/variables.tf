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

  validation {
    condition     = length(setintersection(keys(var.env), ["COGNITO_USER_POOL_ID", "COGNITO_CLIENT_ID", "COGNITO_DOMAIN", "COGNITO_ISSUER"])) == 0
    error_message = "env.COGNITO_* keys are reserved — the platform injects them when auth: cognito is set"
  }
}

variable "secrets" {
  description = "Secret environment variable names injected from SSM Parameter Store. Values are never Terraform inputs; each name resolves to /flightdeck/<app>/<environment>/<name>."
  type        = list(string)
  default     = []

  validation {
    condition     = length(var.secrets) <= 20
    error_message = "secrets supports at most 20 entries."
  }

  validation {
    condition     = alltrue([for name in var.secrets : can(regex("^[A-Z][A-Z0-9_]{0,63}$", name))])
    error_message = "each secrets entry must match ^[A-Z][A-Z0-9_]{0,63}$."
  }

  validation {
    condition     = length(distinct(var.secrets)) == length(var.secrets)
    error_message = "secrets entries must be unique."
  }

  validation {
    condition     = length(setintersection(toset(var.secrets), toset(keys(var.env)))) == 0
    error_message = "a name cannot appear in both secrets and env."
  }

  validation {
    condition = length(setintersection(toset(var.secrets), toset([
      "STORAGE_BUCKET",
      "COGNITO_USER_POOL_ID",
      "COGNITO_CLIENT_ID",
      "COGNITO_DOMAIN",
      "COGNITO_ISSUER",
    ]))) == 0
    error_message = "secrets cannot use platform-reserved STORAGE_BUCKET or COGNITO_* names."
  }
}

variable "storage" {
  description = "Optional platform storage the app needs. \"\" (default) = none, no new resources. \"s3\" = a private, per-environment S3 bucket; its name is injected into the container as the STORAGE_BUCKET env var, and the task role gets scoped read/write/list access to it. \"s3-retained\" = everything \"s3\" provides, plus versioning with 90-day noncurrent retention and force_destroy off — terraform cannot delete the bucket while it holds data, so the ledger survives a stack teardown."
  type        = string
  default     = ""

  validation {
    condition     = contains(["", "s3", "s3-retained"], var.storage)
    error_message = "storage must be \"\" (no storage, the default), \"s3\", or \"s3-retained\"."
  }
}

variable "alerts" {
  description = "Optional log-pattern alerts. Each entry becomes a CloudWatch Logs metric filter on the service's log group plus an alarm that fires on >= 1 matching line in 5 minutes, publishing to the shared alerts topic. [] (default) = no new resources."
  type = list(object({
    name    = string
    pattern = string
  }))
  default = []

  validation {
    condition     = length(var.alerts) <= 10
    error_message = "alerts supports at most 10 entries."
  }

  validation {
    condition     = alltrue([for a in var.alerts : can(regex("^[a-z][a-z0-9-]{0,31}$", a.name))])
    error_message = "each alerts[].name must be lowercase alphanumeric/hyphens, start with a letter, and be at most 32 characters."
  }

  validation {
    condition     = alltrue([for a in var.alerts : length(a.pattern) > 0])
    error_message = "each alerts[].pattern must be a non-empty CloudWatch Logs filter pattern."
  }

  validation {
    condition     = length(distinct([for a in var.alerts : a.name])) == length(var.alerts)
    error_message = "alerts[].name values must be unique."
  }
}

variable "auth" {
  description = "Optional platform authentication. \"\" (default) = none, no new resources. \"cognito\" = a per-environment Cognito user pool with a public (PKCE, secretless) app client and hosted login UI; pool/client identifiers are injected as the reserved COGNITO_* env vars. The task role gains no permissions — apps verify tokens against the pool's public JWKS."
  type        = string
  default     = ""

  validation {
    condition     = contains(["", "cognito"], var.auth)
    error_message = "auth must be \"\" (no auth, the default) or \"cognito\"."
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

variable "alerts_topic_arn" {
  description = "ARN of the shared flightdeck-alerts SNS topic. When set, service alarms publish state changes to it; \"\" (default, and the pre-v0.7.0 caller shape) leaves the alarms visibility-only."
  type        = string
  default     = ""
}
