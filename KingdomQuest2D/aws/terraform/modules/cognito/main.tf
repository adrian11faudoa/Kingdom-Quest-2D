# =============================================================================
# Module: Cognito
# Player authentication with email/password and Google/Apple social login.
# JWT tokens validated by the API — no custom auth server needed.
# =============================================================================

resource "aws_cognito_user_pool" "main" {
  name = "${var.name_prefix}-players"

  # Username / login options
  username_attributes      = ["email"]
  auto_verified_attributes = ["email"]

  username_configuration {
    case_sensitive = false
  }

  # Password policy
  password_policy {
    minimum_length                   = 8
    require_lowercase                = true
    require_numbers                  = true
    require_symbols                  = false
    require_uppercase                = false
    temporary_password_validity_days = 7
  }

  # MFA (optional — off by default for game accounts)
  mfa_configuration = "OFF"

  # Account recovery via email
  account_recovery_setting {
    recovery_mechanism {
      name     = "verified_email"
      priority = 1
    }
  }

  # Standard player attributes
  schema {
    attribute_data_type      = "String"
    name                     = "username"
    required                 = false
    mutable                  = true
    string_attribute_constraints {
      min_length = 3
      max_length = 24
    }
  }

  schema {
    attribute_data_type      = "String"
    name                     = "player_id"
    required                 = false
    mutable                  = false
    string_attribute_constraints {
      min_length = 36
      max_length = 36
    }
  }

  # Email configuration
  email_configuration {
    email_sending_account = "COGNITO_DEFAULT"
  }

  # Verification email
  verification_message_template {
    default_email_option = "CONFIRM_WITH_CODE"
    email_subject        = "Kingdom Quest 2D — Verify your account"
    email_message        = "Welcome to Kingdom Quest 2D! Your verification code is {####}"
  }

  # Token validity
  user_pool_add_ons {
    advanced_security_mode = "AUDIT"  # Monitor for compromised credentials
  }

  tags = { Name = "${var.name_prefix}-cognito-pool" }
}

# ── User Pool Client (game app) ───────────────────────────────────────────────

resource "aws_cognito_user_pool_client" "game_client" {
  name         = "${var.name_prefix}-game-client"
  user_pool_id = aws_cognito_user_pool.main.id

  # Auth flows
  explicit_auth_flows = [
    "ALLOW_USER_PASSWORD_AUTH",
    "ALLOW_REFRESH_TOKEN_AUTH",
    "ALLOW_USER_SRP_AUTH"  # Secure Remote Password — no plaintext password to server
  ]

  # Token validity
  access_token_validity  = 1      # hours
  id_token_validity      = 1      # hours
  refresh_token_validity = 30     # days

  token_validity_units {
    access_token  = "hours"
    id_token      = "hours"
    refresh_token = "days"
  }

  # OAuth2 settings for web/desktop clients
  allowed_oauth_flows                  = ["code"]
  allowed_oauth_scopes                 = ["openid", "email", "profile"]
  allowed_oauth_flows_user_pool_client = true
  callback_urls                        = var.callback_urls
  logout_urls                          = ["https://${var.domain_name}/logout"]

  # Prevent client secret from being exposed in client-side code
  generate_secret = false

  # Prevent user existence errors from being exposed
  prevent_user_existence_errors = "ENABLED"

  supported_identity_providers = ["COGNITO"]
}

# ── Cognito Domain (hosted UI for social login) ───────────────────────────────

resource "aws_cognito_user_pool_domain" "main" {
  domain       = "${var.name_prefix}-auth"
  user_pool_id = aws_cognito_user_pool.main.id
}

# ── Identity Pool (for temporary AWS credentials — e.g. S3 save upload) ───────

resource "aws_cognito_identity_pool" "main" {
  identity_pool_name               = "${var.name_prefix} Players"
  allow_unauthenticated_identities = false

  cognito_identity_providers {
    client_id               = aws_cognito_user_pool_client.game_client.id
    provider_name           = aws_cognito_user_pool.main.endpoint
    server_side_token_check = false
  }

  tags = { Name = "${var.name_prefix}-identity-pool" }
}

# ── Identity Pool IAM Roles ───────────────────────────────────────────────────

# Authenticated players: can upload their own save file only
resource "aws_iam_role" "cognito_authenticated" {
  name = "${var.name_prefix}-cognito-auth-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = { Federated = "cognito-identity.amazonaws.com" }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "cognito-identity.amazonaws.com:aud" = aws_cognito_identity_pool.main.id
        }
        "ForAnyValue:StringLike" = {
          "cognito-identity.amazonaws.com:amr" = "authenticated"
        }
      }
    }]
  })
}

resource "aws_iam_role_policy" "cognito_authenticated" {
  name = "${var.name_prefix}-cognito-auth-policy"
  role = aws_iam_role.cognito_authenticated.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # Players can only read/write their own save directory
        Effect = "Allow"
        Action = ["s3:GetObject", "s3:PutObject"]
        Resource = "arn:aws:s3:::*-player-saves-*/saves/$${cognito-identity.amazonaws.com:sub}/*"
      },
      {
        # Allow CloudFront-signed asset downloads (future feature)
        Effect   = "Allow"
        Action   = ["cloudfront:CreateInvalidation"]
        Resource = "*"
        Condition = { Bool = { "aws:SecureTransport" = "true" } }
      }
    ]
  })
}

resource "aws_cognito_identity_pool_roles_attachment" "main" {
  identity_pool_id = aws_cognito_identity_pool.main.id

  roles = {
    "authenticated" = aws_iam_role.cognito_authenticated.arn
  }
}

# ── Variables ─────────────────────────────────────────────────────────────────

variable "name_prefix"    { type = string }
variable "environment"    { type = string }
variable "domain_name"    { type = string }
variable "callback_urls"  { type = list(string) }

# ── Outputs ───────────────────────────────────────────────────────────────────

output "user_pool_id"       { value = aws_cognito_user_pool.main.id }
output "user_pool_arn"      { value = aws_cognito_user_pool.main.arn }
output "client_id"          { value = aws_cognito_user_pool_client.game_client.id }
output "identity_pool_id"   { value = aws_cognito_identity_pool.main.id }
output "auth_domain"        { value = aws_cognito_user_pool_domain.main.domain }
output "hosted_ui_url"      { value = "https://${aws_cognito_user_pool_domain.main.domain}.auth.${var.environment == "prod" ? "us-east-1" : "us-east-1"}.amazoncognito.com" }
