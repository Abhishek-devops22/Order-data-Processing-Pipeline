data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

# ── KMS key for raw S3 bucket (PII data) ──────────────────────────────────────
resource "aws_kms_key" "raw_data" {
  description             = "CMK for raw orders S3 bucket — encrypts PII data at rest"
  deletion_window_in_days = var.key_deletion_window_days
  enable_key_rotation     = true  # Annual automatic rotation
  multi_region            = false # Single-region, data stays in EU

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowRootAccount"
        Effect = "Allow"
        Principal = {
          AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"
        }
        Action   = "kms:*"
        Resource = "*"
      },
      {
        Sid    = "AllowLambdaEncryptDecrypt"
        Effect = "Allow"
        Principal = {
          AWS = var.lambda_role_arn
        }
        Action = [
          "kms:GenerateDataKey",
          "kms:Decrypt",
          "kms:DescribeKey"
        ]
        Resource = "*"
      },
      {
        Sid    = "AllowS3ServiceEncryption"
        Effect = "Allow"
        Principal = {
          Service = "s3.amazonaws.com"
        }
        Action = [
          "kms:GenerateDataKey",
          "kms:Decrypt"
        ]
        Resource = "*"
      }
    ]
  })

  tags = {
    Name    = "${var.project_name}-raw-data-key-${var.environment}"
    Purpose = "raw-s3-encryption"
  }
}

resource "aws_kms_alias" "raw_data" {
  name          = "alias/${var.project_name}-raw-data-${var.environment}"
  target_key_id = aws_kms_key.raw_data.key_id
}

# ── KMS key for processed S3 bucket (anonymized data) ─────────────────────────
resource "aws_kms_key" "processed_data" {
  description             = "CMK for processed orders S3 bucket — encrypts anonymized data"
  deletion_window_in_days = var.key_deletion_window_days
  enable_key_rotation     = true
  multi_region            = false

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowRootAccount"
        Effect = "Allow"
        Principal = {
          AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"
        }
        Action   = "kms:*"
        Resource = "*"
      },
      {
        Sid    = "AllowLambdaAndGlueEncryptDecrypt"
        Effect = "Allow"
        Principal = {
          AWS = [var.lambda_role_arn, var.glue_role_arn]
        }
        Action = [
          "kms:GenerateDataKey",
          "kms:Decrypt",
          "kms:DescribeKey"
        ]
        Resource = "*"
      }
    ]
  })

  tags = {
    Name    = "${var.project_name}-processed-data-key-${var.environment}"
    Purpose = "processed-s3-encryption"
  }
}

resource "aws_kms_alias" "processed_data" {
  name          = "alias/${var.project_name}-processed-data-${var.environment}"
  target_key_id = aws_kms_key.processed_data.key_id
}

# ── KMS key for Secrets Manager (PII pepper) ──────────────────────────────────
resource "aws_kms_key" "secrets" {
  description             = "CMK for Secrets Manager — encrypts GDPR pseudonymization pepper"
  deletion_window_in_days = var.key_deletion_window_days
  enable_key_rotation     = true
  multi_region            = false

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowRootAccount"
        Effect = "Allow"
        Principal = {
          AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"
        }
        Action   = "kms:*"
        Resource = "*"
      },
      {
        Sid    = "AllowSecretsManagerAndLambda"
        Effect = "Allow"
        Principal = {
          AWS     = [var.lambda_role_arn]
          Service = "secretsmanager.amazonaws.com"
        }
        Action = [
          "kms:GenerateDataKey",
          "kms:Decrypt",
          "kms:DescribeKey"
        ]
        Resource = "*"
      }
    ]
  })

  tags = {
    Name    = "${var.project_name}-secrets-key-${var.environment}"
    Purpose = "secrets-manager-encryption"
  }
}

resource "aws_kms_alias" "secrets" {
  name          = "alias/${var.project_name}-secrets-${var.environment}"
  target_key_id = aws_kms_key.secrets.key_id
}

# ── KMS key for CloudTrail logs ────────────────────────────────────────────────
resource "aws_kms_key" "cloudtrail" {
  description             = "CMK for CloudTrail audit log encryption"
  deletion_window_in_days = var.key_deletion_window_days
  enable_key_rotation     = true
  multi_region            = false

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowRootAccount"
        Effect = "Allow"
        Principal = {
          AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"
        }
        Action   = "kms:*"
        Resource = "*"
      },
      {
        Sid    = "AllowCloudTrailEncrypt"
        Effect = "Allow"
        Principal = {
          Service = "cloudtrail.amazonaws.com"
        }
        Action   = ["kms:GenerateDataKey*", "kms:DescribeKey"]
        Resource = "*"
        Condition = {
          StringLike = {
            "kms:EncryptionContext:aws:cloudtrail:arn" = "arn:aws:cloudtrail:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:trail/*"
          }
        }
      }
    ]
  })

  tags = {
    Name    = "${var.project_name}-cloudtrail-key-${var.environment}"
    Purpose = "audit-log-encryption"
  }
}

resource "aws_kms_alias" "cloudtrail" {
  name          = "alias/${var.project_name}-cloudtrail-${var.environment}"
  target_key_id = aws_kms_key.cloudtrail.key_id
}

# ── KMS key for CloudWatch Logs ───────────────────────────────────────────────
# CloudWatch Logs requires the logs.{region}.amazonaws.com service principal
# in the key policy — it cannot reuse the S3 or Secrets Manager keys.
resource "aws_kms_key" "cloudwatch_logs" {
  description             = "CMK for CloudWatch Logs (Lambda and CloudTrail log groups)"
  deletion_window_in_days = var.key_deletion_window_days
  enable_key_rotation     = true
  multi_region            = false

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowRootAccount"
        Effect = "Allow"
        Principal = {
          AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"
        }
        Action   = "kms:*"
        Resource = "*"
      },
      {
        Sid    = "AllowCloudWatchLogsService"
        Effect = "Allow"
        Principal = {
          Service = "logs.${data.aws_region.current.name}.amazonaws.com"
        }
        Action = [
          "kms:Encrypt*",
          "kms:Decrypt*",
          "kms:ReEncrypt*",
          "kms:GenerateDataKey*",
          "kms:Describe*"
        ]
        Resource = "*"
        Condition = {
          ArnLike = {
            "kms:EncryptionContext:aws:logs:arn" = "arn:aws:logs:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:*"
          }
        }
      }
    ]
  })

  tags = {
    Name    = "${var.project_name}-cloudwatch-logs-key-${var.environment}"
    Purpose = "cloudwatch-logs-encryption"
  }
}

resource "aws_kms_alias" "cloudwatch_logs" {
  name          = "alias/${var.project_name}-cloudwatch-logs-${var.environment}"
  target_key_id = aws_kms_key.cloudwatch_logs.key_id
}
