# Upstream login: the ALB authenticates every request against Cognito before it
# reaches n8n. Only /webhook/* and /webhook-test/* bypass it (listener rules in alb.tf).
# n8n Community Edition has no SSO, so users still see the n8n login after the Cognito login.

resource "aws_cognito_user_pool" "n8n" {
  count = var.enable_alb_auth ? 1 : 0
  name  = local.name

  username_attributes      = ["email"]
  auto_verified_attributes = ["email"]
  mfa_configuration        = "OPTIONAL"
  deletion_protection      = var.deletion_protection ? "ACTIVE" : "INACTIVE"

  software_token_mfa_configuration {
    enabled = true
  }

  # No self sign-up: users are provisioned via var.auth_users only.
  admin_create_user_config {
    allow_admin_create_user_only = true
  }

  password_policy {
    minimum_length                   = 14
    require_lowercase                = true
    require_uppercase                = true
    require_numbers                  = true
    require_symbols                  = true
    temporary_password_validity_days = 3
  }

  account_recovery_setting {
    recovery_mechanism {
      name     = "verified_email"
      priority = 1
    }
  }
}

resource "aws_cognito_user_pool_domain" "n8n" {
  count        = var.enable_alb_auth ? 1 : 0
  domain       = "${local.name}-${local.account_id}"
  user_pool_id = aws_cognito_user_pool.n8n[0].id
}

resource "aws_cognito_user_pool_client" "alb" {
  count        = var.enable_alb_auth ? 1 : 0
  name         = "${local.name}-alb"
  user_pool_id = aws_cognito_user_pool.n8n[0].id

  # The ALB requires a confidential client.
  generate_secret                      = true
  allowed_oauth_flows_user_pool_client = true
  allowed_oauth_flows                  = ["code"]
  allowed_oauth_scopes                 = ["openid", "email"]
  supported_identity_providers         = ["COGNITO"]
  callback_urls                        = ["https://${var.hostname}/oauth2/idpresponse"]
  explicit_auth_flows                  = ["ALLOW_REFRESH_TOKEN_AUTH"]
  prevent_user_existence_errors        = "ENABLED"
}

# Cognito generates the temporary password and emails it; nothing secret ends up in state.
resource "aws_cognito_user" "this" {
  for_each     = var.enable_alb_auth ? toset(var.auth_users) : toset([])
  user_pool_id = aws_cognito_user_pool.n8n[0].id
  username     = each.value

  desired_delivery_mediums = ["EMAIL"]
  attributes = {
    email          = each.value
    email_verified = "true"
  }
}
