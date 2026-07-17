# Optional per-app Cognito authentication (spec §6 v0.6.0: the studio app is
# the first whose spec needs users to sign in). Mirrors storage.tf's shape:
# everything below is conditional on var.auth == "cognito" via the count
# pattern, so the default (auth = "") creates zero new resources here —
# existing apps adopting v0.6.0 without opting in see an empty diff.

# Keyed on svc_name (not name): dev and prod stacks of the same app get
# separate user pools automatically — test accounts never reach prod, the
# same isolation-for-free the storage bucket gets.
resource "aws_cognito_user_pool" "auth" {
  count = var.auth == "cognito" ? 1 : 0
  name  = "flightdeck-${local.svc_name}"

  # Deliberate, mirrors the storage bucket's force_destroy: flightdeck is a
  # teardown-first demo platform. User accounts die with the stack — stated
  # loudly in the docs, not a durability promise.
  deletion_protection = "INACTIVE"

  # Email is the username. Cognito's built-in email sender caps around 50
  # messages/day — plenty at demo scale, and it needs no SES setup.
  username_attributes      = ["email"]
  auto_verified_attributes = ["email"]

  password_policy {
    minimum_length                   = 12
    require_lowercase                = true
    require_uppercase                = true
    require_numbers                  = true
    require_symbols                  = true
    temporary_password_validity_days = 7
  }

  account_recovery_setting {
    recovery_mechanism {
      name     = "verified_email"
      priority = 1
    }
  }
}

# Public client, PKCE only — no secret is ever generated, so this feature
# has zero dependency on secrets injection (which v1 doesn't have; spec
# §11). Apps run the OIDC authorization-code flow against the hosted UI and
# verify the resulting JWTs offline via the issuer's public JWKS.
resource "aws_cognito_user_pool_client" "auth" {
  count        = var.auth == "cognito" ? 1 : 0
  name         = "flightdeck-${local.svc_name}"
  user_pool_id = aws_cognito_user_pool.auth[0].id

  generate_secret = false

  explicit_auth_flows = [
    "ALLOW_USER_SRP_AUTH",
    "ALLOW_REFRESH_TOKEN_AUTH",
  ]

  supported_identity_providers         = ["COGNITO"]
  allowed_oauth_flows_user_pool_client = true
  allowed_oauth_flows                  = ["code"]
  allowed_oauth_scopes                 = ["openid", "email", "profile"]

  # /auth/callback is the contract path (docs/contract.md). The localhost
  # redirect exists on the dev client only — prod never accepts a local
  # redirect target.
  callback_urls = concat(
    ["https://${local.svc_name}.${var.child_zone_name}/auth/callback"],
    var.environment == "dev" ? ["http://localhost:${var.port}/auth/callback"] : []
  )
  logout_urls = concat(
    ["https://${local.svc_name}.${var.child_zone_name}/"],
    var.environment == "dev" ? ["http://localhost:${var.port}/"] : []
  )

  # Uniform "incorrect username or password" responses — sign-in attempts
  # can't be used to enumerate which addresses have accounts.
  prevent_user_existence_errors = "ENABLED"
}

# Cognito-hosted login UI. The prefix embeds the account id because Cognito
# domain prefixes are region-global across ALL AWS accounts — same reason
# the storage bucket name carries it.
resource "aws_cognito_user_pool_domain" "auth" {
  count        = var.auth == "cognito" ? 1 : 0
  domain       = "flightdeck-${local.svc_name}-${data.aws_caller_identity.current.account_id}"
  user_pool_id = aws_cognito_user_pool.auth[0].id
}
