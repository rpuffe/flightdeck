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

variable "apps" {
  description = "THE app registry: adding a name here creates per-app IAM and dev/prod ECR resources when bootstrap is re-applied. Everything else is app-repo-side."
  type        = list(string)
  default     = ["ping", "todo", "tasks", "board", "golf"]
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
