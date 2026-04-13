data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

# ── Lambda Execution Role ─────────────────────────────────────────────────────
# Role is created in root main.tf as a placeholder (to break KMS circular dep).
# Here we only attach policies to it using the passed-in role ID/ARN.
locals {
  lambda_exec_role_id  = var.lambda_exec_role_id
  lambda_exec_role_arn = var.lambda_exec_role_arn
  glue_role_id         = var.glue_role_id
  glue_role_arn        = var.glue_role_arn
}

# ── CloudWatch Logs — Lambda writes structured logs ───────────────────────────
resource "aws_iam_role_policy" "lambda_logs" {
  name = "cloudwatch-logs"
  role = local.lambda_exec_role_id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "logs:CreateLogGroup",
        "logs:CreateLogStream",
        "logs:PutLogEvents"
      ]
      Resource = "arn:aws:logs:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:log-group:/aws/lambda/${var.project_name}-*:*"
    }]
  })
}

# ── S3 — write-only to raw bucket, write-only to processed bucket ─────────────
resource "aws_iam_role_policy" "lambda_s3" {
  name = "s3-write-only"
  role = local.lambda_exec_role_id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "WriteRawOrders"
        Effect = "Allow"
        Action = ["s3:PutObject"]
        Resource = "${var.raw_bucket_arn}/raw/*"
      },
      {
        Sid    = "WriteProcessedOrders"
        Effect = "Allow"
        Action = ["s3:PutObject"]
        Resource = "${var.processed_bucket_arn}/processed/*"
      }
    ]
  })
}

# ── Secrets Manager — read-only access to the PII pepper secret only ──────────
resource "aws_iam_role_policy" "lambda_secrets" {
  name = "secrets-manager-read-pepper"
  role = local.lambda_exec_role_id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid    = "ReadPepperSecret"
      Effect = "Allow"
      Action = [
        "secretsmanager:GetSecretValue",
        "secretsmanager:DescribeSecret"
      ]
      Resource = var.pepper_secret_arn
    }]
  })
}

# ── KMS — encrypt/decrypt for raw and processed buckets + secrets ─────────────
resource "aws_iam_role_policy" "lambda_kms" {
  name = "kms-encrypt-decrypt"
  role = local.lambda_exec_role_id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "kms:GenerateDataKey",
        "kms:Decrypt",
        "kms:DescribeKey"
      ]
      Resource = var.kms_key_arns
    }]
  })
}

# ── Glue Role for Athena/Crawler ──────────────────────────────────────────────
# Role is created in root main.tf as a placeholder (to break KMS circular dep).
# Here we only attach policies.

resource "aws_iam_role_policy_attachment" "glue_service" {
  role       = local.glue_role_id
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSGlueServiceRole"
}

resource "aws_iam_role_policy" "glue_s3" {
  name = "s3-read-processed"
  role = local.glue_role_id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = ["s3:GetObject", "s3:ListBucket"]
      Resource = [
        var.processed_bucket_arn,
        "${var.processed_bucket_arn}/*"
      ]
    }]
  })
}

resource "aws_iam_role_policy" "glue_kms" {
  name = "kms-decrypt-processed"
  role = local.glue_role_id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = ["kms:Decrypt", "kms:DescribeKey", "kms:GenerateDataKey"]
      Resource = [var.processed_data_key_arn]
    }]
  })
}

# ── Deny policy: block Lambda from READING raw PII data ───────────────────────
# Lambda only needs to WRITE to raw bucket (no read-back of PII)
resource "aws_iam_role_policy" "lambda_deny_raw_read" {
  name = "deny-raw-bucket-read"
  role = local.lambda_exec_role_id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Deny"
      Action   = ["s3:GetObject", "s3:ListBucket"]
      Resource = [var.raw_bucket_arn, "${var.raw_bucket_arn}/*"]
    }]
  })
}
