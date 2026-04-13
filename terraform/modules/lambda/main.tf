# ── CloudWatch Log Group (created before Lambda so retention is set) ──────────
resource "aws_cloudwatch_log_group" "lambda" {
  name              = "/aws/lambda/${var.function_name}"
  retention_in_days = 90
  kms_key_id        = var.cloudwatch_kms_key_arn

  tags = {
    Name    = "${var.function_name}-logs"
    Purpose = "lambda-application-logs"
  }
}

# ── Lambda Function ───────────────────────────────────────────────────────────
resource "aws_lambda_function" "order_processor" {
  function_name    = var.function_name
  description      = "GDPR-compliant order processor. Pseudonymizes PII, writes to S3 raw (with PII) and processed (anonymized) buckets."
  filename         = var.function_zip_path
  source_code_hash = var.function_zip_hash
  handler          = "handler.lambda_handler"
  runtime          = "python3.12"
  role             = var.lambda_role_arn
  memory_size      = var.memory_mb
  timeout          = var.timeout_seconds

  environment {
    variables = {
      RAW_BUCKET_NAME      = var.raw_bucket_name
      PROCESSED_BUCKET_NAME = var.processed_bucket_name
      PEPPER_SECRET_ARN    = var.pepper_secret_arn
      ENVIRONMENT          = var.environment
    }
  }

  # Enable X-Ray tracing for distributed request observability
  tracing_config {
    mode = "Active"
  }

  depends_on = [aws_cloudwatch_log_group.lambda]

  tags = {
    Name    = var.function_name
    Purpose = "order-processing"
  }
}

# ── Lambda Function URL (alternative to API Gateway for direct HTTPS access) ──
# API Gateway is preferred for stage management and rate limiting.

# ── CloudWatch Alarms ─────────────────────────────────────────────────────────
resource "aws_cloudwatch_metric_alarm" "lambda_errors" {
  alarm_name          = "${var.function_name}-errors"
  alarm_description   = "Lambda function error rate exceeds threshold"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "Errors"
  namespace           = "AWS/Lambda"
  period              = 60
  statistic           = "Sum"
  threshold           = 5
  treat_missing_data  = "notBreaching"

  dimensions = {
    FunctionName = aws_lambda_function.order_processor.function_name
  }

  alarm_actions = var.alarm_sns_arns

  tags = { Name = "${var.function_name}-error-alarm" }
}

resource "aws_cloudwatch_metric_alarm" "lambda_duration" {
  alarm_name          = "${var.function_name}-duration"
  alarm_description   = "Lambda p99 duration approaching timeout"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 3
  metric_name         = "Duration"
  namespace           = "AWS/Lambda"
  period              = 60
  extended_statistic  = "p99"
  threshold           = var.timeout_seconds * 1000 * 0.8 # 80% of timeout
  treat_missing_data  = "notBreaching"

  dimensions = {
    FunctionName = aws_lambda_function.order_processor.function_name
  }

  tags = { Name = "${var.function_name}-duration-alarm" }
}
