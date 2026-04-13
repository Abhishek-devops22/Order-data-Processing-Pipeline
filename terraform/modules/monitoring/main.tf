data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

# ── CloudWatch Log Group for CloudTrail ───────────────────────────────────────
resource "aws_cloudwatch_log_group" "cloudtrail" {
  name              = "/aws/cloudtrail/${var.project_name}"
  retention_in_days = 90
  kms_key_id        = var.cloudwatch_logs_key_arn

  tags = { Name = "${var.project_name}-cloudtrail-logs" }
}

# ── IAM Role: allow CloudTrail to write to CloudWatch Logs ───────────────────
resource "aws_iam_role" "cloudtrail_cloudwatch" {
  name = "${var.project_name}-cloudtrail-cw-${var.environment}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "cloudtrail.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "cloudtrail_cloudwatch" {
  name = "cloudwatch-logs-write"
  role = aws_iam_role.cloudtrail_cloudwatch.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "logs:CreateLogStream",
        "logs:PutLogEvents"
      ]
      Resource = "${aws_cloudwatch_log_group.cloudtrail.arn}:*"
    }]
  })
}

# ── CloudTrail — audit log for ALL S3 data events + management events ─────────
resource "aws_cloudtrail" "pipeline" {
  name                          = "${var.project_name}-audit-trail-${var.environment}"
  s3_bucket_name                = var.cloudtrail_bucket_id
  include_global_service_events = true
  is_multi_region_trail         = false # Single EU region for GDPR
  enable_log_file_validation    = true  # Detect tampering with log files
  kms_key_id                    = var.cloudtrail_kms_key_arn

  cloud_watch_logs_group_arn = "${aws_cloudwatch_log_group.cloudtrail.arn}:*"
  cloud_watch_logs_role_arn  = aws_iam_role.cloudtrail_cloudwatch.arn

  # Log data events for both S3 buckets (read + write access audit)
  event_selector {
    read_write_type           = "All"
    include_management_events = true

    data_resource {
      type   = "AWS::S3::Object"
      values = [
        "${var.raw_bucket_arn}/",
        "${var.processed_bucket_arn}/"
      ]
    }
  }

  # Log Lambda invocations (who called the order processor)
  event_selector {
    read_write_type           = "WriteOnly"
    include_management_events = false

    data_resource {
      type   = "AWS::Lambda::Function"
      values = [var.lambda_function_arn]
    }
  }

  tags = {
    Name        = "${var.project_name}-audit-trail-${var.environment}"
    GDPRArticle = "article-30"
    Purpose     = "audit-logging"
  }

  depends_on = [aws_iam_role_policy.cloudtrail_cloudwatch]
}

# ── SNS topic for alarms (optional — email subscription) ─────────────────────
resource "aws_sns_topic" "alerts" {
  name              = "${var.project_name}-alerts-${var.environment}"
  kms_master_key_id = "alias/aws/sns"

  tags = { Name = "${var.project_name}-alerts" }
}

resource "aws_sns_topic_subscription" "email" {
  count     = var.alert_email != "" ? 1 : 0
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

# ── CloudWatch Dashboard ───────────────────────────────────────────────────────
resource "aws_cloudwatch_dashboard" "pipeline" {
  dashboard_name = "${var.project_name}-pipeline-${var.environment}"

  dashboard_body = jsonencode({
    widgets = [
      {
        type   = "metric"
        x = 0
        y = 0
        width = 12
        height = 6
        properties = {
          title  = "Lambda Invocations & Errors"
          region = data.aws_region.current.name
          period = 60
          stat   = "Sum"
          metrics = [
            ["AWS/Lambda", "Invocations", "FunctionName", var.lambda_function_name],
            ["AWS/Lambda", "Errors", "FunctionName", var.lambda_function_name],
            ["AWS/Lambda", "Throttles", "FunctionName", var.lambda_function_name]
          ]
        }
      },
      {
        type   = "metric"
        x = 12
        y = 0
        width = 12
        height = 6
        properties = {
          title  = "API Gateway Requests & Errors"
          region = data.aws_region.current.name
          period = 60
          stat   = "Sum"
          metrics = [
            ["AWS/ApiGateway", "Count", "ApiName", var.api_name, "Stage", "prod"],
            ["AWS/ApiGateway", "4XXError", "ApiName", var.api_name, "Stage", "prod"],
            ["AWS/ApiGateway", "5XXError", "ApiName", var.api_name, "Stage", "prod"]
          ]
        }
      },
      {
        type   = "metric"
        x      = 0
        y = 6
        width = 12
        height = 6
        properties = {
          title  = "Lambda Duration (p50 / p99)"
          region = data.aws_region.current.name
          period = 60
          stat   = "p99"
          metrics = [
            ["AWS/Lambda", "Duration", "FunctionName", var.lambda_function_name, { stat = "p50", label = "p50" }],
            ["AWS/Lambda", "Duration", "FunctionName", var.lambda_function_name, { stat = "p99", label = "p99" }]
          ]
        }
      }
    ]
  })
}

# ── S3 event notification: alert if anyone puts to raw bucket outside Lambda ──
# (belt-and-suspenders on top of bucket policy)
resource "aws_cloudwatch_log_metric_filter" "s3_raw_access" {
  name           = "${var.project_name}-raw-bucket-access"
  pattern        = "{ ($.eventSource = \"s3.amazonaws.com\") && ($.requestParameters.bucketName = \"${var.raw_bucket_name}\") && ($.userIdentity.arn != \"${var.lambda_role_arn}\") }"
  log_group_name = aws_cloudwatch_log_group.cloudtrail.name

  metric_transformation {
    name          = "UnauthorizedRawBucketAccess"
    namespace     = "${var.project_name}/Security"
    value         = "1"
    default_value = "0"
  }
}
