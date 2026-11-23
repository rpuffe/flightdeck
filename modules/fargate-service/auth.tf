resource "aws_cognito_user_pool" "auth" {
  count = var.auth == "cognito" ? 1 : 0
  name  = "flightdeck-${local.svc_name}"

  deletion_protection = "INACTIVE"

  # Cognito's default email sender is capped at 50 messages/day per AWS
  # account, shared by every user pool in it.
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

  tags = {
    flightdeck-app = var.name
  }
}

resource "aws_cognito_user_pool_client" "auth" {
  count        = var.auth == "cognito" ? 1 : 0
  name         = "flightdeck-${local.svc_name}"
  user_pool_id = aws_cognito_user_pool.auth[0].id

  generate_secret = false

  explicit_auth_flows = [
    "ALLOW_REFRESH_TOKEN_AUTH",
  ]

  supported_identity_providers         = ["COGNITO"]
  allowed_oauth_flows_user_pool_client = true
  allowed_oauth_flows                  = ["code"]
  allowed_oauth_scopes                 = ["openid", "email", "profile"]

  callback_urls = concat(
    ["https://${local.svc_name}.${var.child_zone_name}/auth/callback"],
    var.environment == "dev" ? ["http://localhost:${var.port}/auth/callback"] : []
  )
  logout_urls = concat(
    ["https://${local.svc_name}.${var.child_zone_name}/"],
    var.environment == "dev" ? ["http://localhost:${var.port}/"] : []
  )

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
