variable "region" {
  description = "AWS region for all flightdeck resources"
  type        = string
  default     = "us-east-1"
}

variable "parent_zone_name" {
  description = "Existing Route53 zone delegated from. DATA SOURCE ONLY apart from the single NS delegation record (spec 5b)."
  type        = string
  default     = "robertpuffe.com"
}

variable "subdomain" {
  description = "Child zone label under the parent zone; apps live at <name>.<subdomain>.<parent_zone_name>"
  type        = string
  default     = "fd"
}

variable "github_owner" {
  description = "GitHub owner containing the registered repositories trusted by their per-app OIDC deploy roles"
  type        = string
  default     = "rpuffe"
}

variable "github_owner_id" {
  description = "Immutable GitHub database ID for github_owner, used by repositories with immutable OIDC subject claims"
  type        = string
  default     = "153844170"

  validation {
    condition     = can(regex("^[0-9]+$", var.github_owner_id))
    error_message = "github_owner_id must be a numeric GitHub database ID."
  }
}

variable "apps" {
  description = "THE app registry: adding a name here creates per-app IAM and dev/prod ECR resources when bootstrap is re-applied. Everything else is app-repo-side."
  type        = list(string)
  default     = ["ping", "todo", "tasks", "board", "golf", "studio"]
}

variable "github_repository_ids" {
  description = "Immutable GitHub database IDs keyed by registered app name; required before bootstrap can create that app's deploy role"
  type        = map(string)
  default = {
    ping   = "1296998462"
    todo   = "1297061622"
    tasks  = "1297073678"
    board  = "1297095053"
    golf   = "1297810535"
    studio = "1304276421"
  }

  validation {
    condition = alltrue([
      for repository_id in values(var.github_repository_ids) :
      can(regex("^[0-9]+$", repository_id))
    ])
    error_message = "Every github_repository_ids value must be a numeric GitHub database ID."
  }
}

variable "budget_limit_usd" {
  description = "Monthly budget alarm threshold in USD"
  type        = string
  default     = "30"
}

variable "alert_email" {
  description = "Email for budget notifications. Set via bootstrap.auto.tfvars (gitignored) — see example.tfvars."
  type        = string
}
