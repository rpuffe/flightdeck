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

variable "mail_senders" {
  description = "Apps authorized to send mail through SES, mapped to the exact prod From addresses each may use. Operator-controlled on purpose: an app cannot grant itself sending by editing its own manifest, and an app absent from this map gets no ses:* in its permissions boundary at all — so enabling mail for one app leaves every other app's ceiling byte-identical. The platform-zone dev address is authorized automatically for a listed app and must not be repeated here. Each prod domain must be a verified SES identity: list it in mail_managed_zones to have Terraform verify it, or verify it out of band when its DNS lives elsewhere. Example: { studio = [\"noreply@example.com\"] }"
  type        = map(list(string))
  default     = {}

  validation {
    condition     = length(setsubtract(keys(var.mail_senders), toset(var.apps))) == 0
    error_message = "Every mail_senders key must name an app registered in var.apps."
  }

  validation {
    condition = alltrue([
      for addresses in values(var.mail_senders) : alltrue([
        for address in addresses : can(regex("^[a-z0-9._%+-]+@[a-z0-9.-]+\\.[a-z]{2,}$", address))
      ])
    ])
    error_message = "Every mail_senders address must be a bare lowercase email address with no display name, e.g. billing@example.com."
  }

  validation {
    condition = alltrue([
      for addresses in values(var.mail_senders) : length(addresses) > 0
    ])
    error_message = "An app listed in mail_senders must authorize at least one prod From address; remove the key entirely to revoke sending."
  }
}

variable "mail_managed_zones" {
  description = "Sending domains whose Route53 hosted zone lives in THIS account and should get a Terraform-managed SES identity plus DKIM/SPF/DMARC records. Domains left out of this list still work — they are verified in the SES console and their records added at whatever registrar holds them — this list only automates the ones flightdeck can reach. Each entry must be an apex domain with an existing public hosted zone, and Terraform will create a TXT record at that apex: a domain that already publishes SPF must be left off this list and merged by hand instead. Example: [\"sephrasmusicstudio.com\"]"
  type        = list(string)
  default     = []

  validation {
    condition = alltrue([
      for domain in var.mail_managed_zones : can(regex("^[a-z0-9-]+(\\.[a-z0-9-]+)+$", domain))
    ])
    error_message = "Every mail_managed_zones entry must be a bare lowercase apex domain, e.g. example.com (no scheme, no trailing dot, no address)."
  }

  validation {
    condition     = length(distinct(var.mail_managed_zones)) == length(var.mail_managed_zones)
    error_message = "mail_managed_zones entries must be unique."
  }

  # The parent zone hosts a live personal site and is data-source-only apart
  # from the single NS delegation record (spec 5b, edge.tf). Listing it here
  # would have Terraform write SPF/DMARC TXT records at that apex — an SPF
  # "-all" on a domain with real mailboxes silently breaks their delivery.
  # A hard failure, not a silent filter: the operator meant something by the
  # entry and needs to see that it cannot be honoured.
  validation {
    condition     = !contains(var.mail_managed_zones, var.parent_zone_name)
    error_message = "mail_managed_zones must not contain the parent zone (var.parent_zone_name). It hosts a live site and is data-source-only apart from the NS delegation record; writing SPF/DMARC there would affect mail flightdeck does not own."
  }

  # The child zone gets its identity from aws_sesv2_email_identity.child_zone
  # unconditionally; listing it here would declare a second identity and a
  # duplicate record set for the same domain.
  validation {
    condition     = !contains(var.mail_managed_zones, "${var.subdomain}.${var.parent_zone_name}")
    error_message = "mail_managed_zones must not contain the flightdeck child zone — its SES identity and DNS records are already managed unconditionally in ses.tf."
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
