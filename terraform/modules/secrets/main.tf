resource "random_password" "pii_pepper" {
  length  = 48
  special = false
  # High entropy, no special chars to avoid escaping issues in Lambda
}

resource "aws_secretsmanager_secret" "pii_pepper" {
  name                    = "${var.project_name}/pii-pepper/${var.environment}"
  description             = "GDPR pseudonymization pepper. Used to HMAC-SHA256 customer emails. Never rotated automatically — rotation requires re-pseudonymizing all existing records."
  kms_key_id              = var.kms_key_arn
  recovery_window_in_days = 0 # Allow immediate deletion on destroy (avoids name collision on re-apply)

  # Pepper must NOT be automatically rotated.
  # Rotation invalidates all existing pseudonymous customer IDs.
  # Manual rotation only, coordinated with data erasure team.

  tags = {
    Name        = "${var.project_name}-pii-pepper-${var.environment}"
    GDPRRole    = "pseudonymization-key"
    RotationPolicy = "manual-only"
  }
}

resource "aws_secretsmanager_secret_version" "pii_pepper" {
  secret_id     = aws_secretsmanager_secret.pii_pepper.id
  secret_string = random_password.pii_pepper.result
}

# Resource policy: only Lambda execution role can read this secret
resource "aws_secretsmanager_secret_policy" "pii_pepper" {
  secret_arn = aws_secretsmanager_secret.pii_pepper.arn
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowLambdaReadOnly"
        Effect = "Allow"
        Principal = {
          AWS = var.lambda_role_arn
        }
        Action   = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]
        Resource = "*"
      },
      {
        Sid    = "DenyAllOthers"
        Effect = "Deny"
        Principal = "*"
        Action   = "secretsmanager:GetSecretValue"
        Resource = "*"
        Condition = {
          StringNotEquals = {
            "aws:PrincipalArn" = [
              var.lambda_role_arn,
              var.admin_role_arn
            ]
          }
        }
      }
    ]
  })
}
