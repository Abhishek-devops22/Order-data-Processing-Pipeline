data "aws_caller_identity" "current" {}

# ── Package Lambda function into ZIP ─────────────────────────────────────────
# archive_file zips the function/ directory automatically on every apply.
# No pip install needed — only stdlib + boto3 (pre-installed in Lambda runtime).
data "archive_file" "function" {
  type        = "zip"
  source_dir  = "${path.module}/../function"
  output_path = "${path.module}/function.zip"
  excludes    = ["tests", "__pycache__", "*.pyc", "requirements.txt"]
}

# ── Phase 1: IAM placeholders (roles needed before KMS policies) ──────────────
# We create placeholder roles first so KMS key policies can reference their ARNs.
resource "aws_iam_role" "lambda_exec_placeholder" {
  name = "${var.project_name}-lambda-exec-${var.environment}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = { ManagedBy = "terraform" }
}

resource "aws_iam_role" "glue_placeholder" {
  name = "${var.project_name}-glue-${var.environment}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "glue.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = { ManagedBy = "terraform" }
}

# ── Phase 2: KMS keys ─────────────────────────────────────────────────────────
module "kms" {
  source = "./modules/kms"

  project_name             = var.project_name
  environment              = var.environment
  lambda_role_arn          = aws_iam_role.lambda_exec_placeholder.arn
  glue_role_arn            = aws_iam_role.glue_placeholder.arn
  key_deletion_window_days = var.environment == "prod" ? 30 : 7
}

# ── Phase 3: Secrets Manager ──────────────────────────────────────────────────
module "secrets" {
  source = "./modules/secrets"

  project_name    = var.project_name
  environment     = var.environment
  kms_key_arn     = module.kms.secrets_key_arn
  lambda_role_arn = aws_iam_role.lambda_exec_placeholder.arn
  admin_role_arn  = data.aws_caller_identity.current.arn
}

# ── Phase 4: S3 Buckets ───────────────────────────────────────────────────────
module "storage" {
  source = "./modules/storage"

  project_name             = var.project_name
  environment              = var.environment
  raw_kms_key_arn          = module.kms.raw_data_key_arn
  processed_kms_key_arn    = module.kms.processed_data_key_arn
  cloudtrail_kms_key_arn   = module.kms.cloudtrail_key_arn
  lambda_role_arn          = aws_iam_role.lambda_exec_placeholder.arn
  raw_retention_days       = var.raw_data_retention_days
  processed_retention_days = var.processed_data_retention_days
  gdpr_admin_arn           = data.aws_caller_identity.current.arn
}

# ── Phase 5: Full IAM (with all resource ARNs now known) ──────────────────────
# Passes placeholder role IDs/ARNs so the module only attaches policies,
# avoiding duplicate role creation (EntityAlreadyExists 409).
module "iam" {
  source = "./modules/iam"

  project_name           = var.project_name
  environment            = var.environment
  raw_bucket_arn         = module.storage.raw_bucket_arn
  processed_bucket_arn   = module.storage.processed_bucket_arn
  pepper_secret_arn      = module.secrets.pepper_secret_arn
  processed_data_key_arn = module.kms.processed_data_key_arn
  kms_key_arns = [
    module.kms.raw_data_key_arn,
    module.kms.processed_data_key_arn,
    module.kms.secrets_key_arn,
  ]

  lambda_exec_role_id  = aws_iam_role.lambda_exec_placeholder.id
  lambda_exec_role_arn = aws_iam_role.lambda_exec_placeholder.arn
  glue_role_id         = aws_iam_role.glue_placeholder.id
  glue_role_arn        = aws_iam_role.glue_placeholder.arn
}

# ── Phase 6: Athena / Glue analytics ─────────────────────────────────────────
module "analytics" {
  source = "./modules/analytics"

  project_name          = var.project_name
  environment           = var.environment
  processed_bucket_name = module.storage.processed_bucket_name
  processed_kms_key_arn = module.kms.processed_data_key_arn
  athena_results_bucket = module.storage.athena_results_bucket
  glue_role_arn         = module.iam.glue_role_arn
}

# ── Phase 7: Lambda function ──────────────────────────────────────────────────
module "lambda" {
  source = "./modules/lambda"

  function_name         = "${var.project_name}-order-processor-${var.environment}"
  environment           = var.environment
  function_zip_path     = data.archive_file.function.output_path
  function_zip_hash     = data.archive_file.function.output_base64sha256
  lambda_role_arn       = module.iam.lambda_exec_role_arn
  raw_bucket_name       = module.storage.raw_bucket_id
  processed_bucket_name = module.storage.processed_bucket_id
  pepper_secret_arn     = module.secrets.pepper_secret_arn
  cloudwatch_kms_key_arn = module.kms.cloudwatch_logs_key_arn
  memory_mb             = var.lambda_memory_mb
  timeout_seconds       = var.lambda_timeout_seconds
}

# ── Phase 8: API Gateway ──────────────────────────────────────────────────────
module "api_gateway" {
  source = "./modules/api_gateway"

  project_name         = var.project_name
  environment          = var.environment
  lambda_invoke_arn    = module.lambda.invoke_arn
  lambda_function_name = module.lambda.function_name
}

# ── Phase 9: Monitoring (CloudTrail + alarms) ─────────────────────────────────
module "monitoring" {
  source = "./modules/monitoring"

  project_name           = var.project_name
  environment            = var.environment
  cloudtrail_bucket_id   = module.storage.cloudtrail_bucket_id
  cloudtrail_kms_key_arn  = module.kms.cloudtrail_key_arn
  cloudwatch_logs_key_arn = module.kms.cloudwatch_logs_key_arn
  raw_bucket_arn         = module.storage.raw_bucket_arn
  raw_bucket_name        = module.storage.raw_bucket_id
  processed_bucket_arn   = module.storage.processed_bucket_arn
  lambda_function_arn    = module.lambda.function_arn
  lambda_function_name   = module.lambda.function_name
  lambda_role_arn        = module.iam.lambda_exec_role_arn
  api_name               = "${var.project_name}-orders-api-${var.environment}"
  alert_email            = var.alert_email
}
