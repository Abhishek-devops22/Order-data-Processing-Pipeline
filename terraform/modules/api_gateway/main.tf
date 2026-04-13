data "aws_region" "current" {}
data "aws_caller_identity" "current" {}

# ── Account-level: CloudWatch Logs role for API Gateway ───────────────────────
# Required once per account/region for method-level logging to work.
resource "aws_iam_role" "api_gateway_cloudwatch" {
  name = "${var.project_name}-apigw-cw-${var.environment}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "apigateway.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "api_gateway_cloudwatch" {
  role       = aws_iam_role.api_gateway_cloudwatch.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonAPIGatewayPushToCloudWatchLogs"
}

resource "aws_api_gateway_account" "this" {
  cloudwatch_role_arn = aws_iam_role.api_gateway_cloudwatch.arn

  depends_on = [aws_iam_role_policy_attachment.api_gateway_cloudwatch]
}

# ── REST API (produces the required URL format: /prod/orders) ─────────────────
resource "aws_api_gateway_rest_api" "orders" {
  name        = "${var.project_name}-orders-api-${var.environment}"
  description = "GDPR-compliant order ingestion endpoint. HTTPS-only. Backed by Lambda."

  endpoint_configuration {
    types = ["REGIONAL"]
  }

  tags = {
    Name = "${var.project_name}-orders-api-${var.environment}"
  }
}

# ── /orders resource ──────────────────────────────────────────────────────────
resource "aws_api_gateway_resource" "orders" {
  rest_api_id = aws_api_gateway_rest_api.orders.id
  parent_id   = aws_api_gateway_rest_api.orders.root_resource_id
  path_part   = "orders"
}

# ── POST /orders method ───────────────────────────────────────────────────────
resource "aws_api_gateway_method" "post_orders" {
  rest_api_id      = aws_api_gateway_rest_api.orders.id
  resource_id      = aws_api_gateway_resource.orders.id
  http_method      = "POST"
  authorization    = "NONE"
  api_key_required = false

  request_validator_id = aws_api_gateway_request_validator.body.id

  request_models = {
    "application/json" = aws_api_gateway_model.order_request.name
  }
}

# ── Request body validation ───────────────────────────────────────────────────
resource "aws_api_gateway_request_validator" "body" {
  rest_api_id           = aws_api_gateway_rest_api.orders.id
  name                  = "validate-body"
  validate_request_body = true
}

resource "aws_api_gateway_model" "order_request" {
  rest_api_id  = aws_api_gateway_rest_api.orders.id
  name         = "OrderRequest"
  description  = "Inbound order JSON schema"
  content_type = "application/json"

  schema = jsonencode({
    "$schema" = "http://json-schema.org/draft-04/schema#"
    title     = "OrderRequest"
    type      = "object"
    required  = ["order_id", "timestamp", "customer", "items", "total"]
    properties = {
      order_id  = { type = "string" }
      timestamp = { type = "string" }
      customer = {
        type     = "object"
        required = ["email", "name", "address"]
        properties = {
          email   = { type = "string" }
          name    = { type = "string" }
          address = { type = "string" }
        }
      }
      items = {
        type     = "array"
        minItems = 1
        items = {
          type = "object"
          properties = {
            sku      = { type = "string" }
            quantity = { type = "integer" }
            price    = { type = "number" }
          }
        }
      }
      total        = { type = "number" }
      currency     = { type = "string" }
      payment_last4 = { type = "string" }
    }
  })
}

# ── Lambda integration ────────────────────────────────────────────────────────
resource "aws_api_gateway_integration" "lambda" {
  rest_api_id             = aws_api_gateway_rest_api.orders.id
  resource_id             = aws_api_gateway_resource.orders.id
  http_method             = aws_api_gateway_method.post_orders.http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = var.lambda_invoke_arn
}

resource "aws_lambda_permission" "api_gateway" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = var.lambda_function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_api_gateway_rest_api.orders.execution_arn}/*/POST/orders"
}

# ── Deployment and prod stage ─────────────────────────────────────────────────
resource "aws_api_gateway_deployment" "orders" {
  rest_api_id = aws_api_gateway_rest_api.orders.id

  triggers = {
    redeployment = sha1(jsonencode([
      aws_api_gateway_resource.orders.id,
      aws_api_gateway_method.post_orders.id,
      aws_api_gateway_integration.lambda.id,
    ]))
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_api_gateway_stage" "prod" {
  deployment_id = aws_api_gateway_deployment.orders.id
  rest_api_id   = aws_api_gateway_rest_api.orders.id
  stage_name    = "prod"
  description   = "Production stage"

  # Enable CloudWatch access logging
  access_log_settings {
    destination_arn = aws_cloudwatch_log_group.api_gateway.arn
    format = jsonencode({
      requestId      = "$context.requestId"
      ip             = "$context.identity.sourceIp"
      requestTime    = "$context.requestTime"
      httpMethod     = "$context.httpMethod"
      resourcePath   = "$context.resourcePath"
      status         = "$context.status"
      responseLength = "$context.responseLength"
      # Deliberately omit: userAgent (potential fingerprinting), body (contains PII)
    })
  }

  xray_tracing_enabled = true

  depends_on = [aws_api_gateway_account.this]

  tags = { Name = "${var.project_name}-api-prod" }
}

# ── Stage settings: throttling ────────────────────────────────────────────────
resource "aws_api_gateway_method_settings" "orders" {
  rest_api_id = aws_api_gateway_rest_api.orders.id
  stage_name  = aws_api_gateway_stage.prod.stage_name
  method_path = "orders/POST"

  settings {
    throttling_burst_limit   = 100
    throttling_rate_limit    = 50
    metrics_enabled          = true
    logging_level            = "INFO"
    data_trace_enabled       = false # NEVER enable — would log request body (PII)
  }
}

# ── API Gateway CloudWatch Log Group ─────────────────────────────────────────
resource "aws_cloudwatch_log_group" "api_gateway" {
  name              = "/aws/api-gateway/${var.project_name}-orders-${var.environment}"
  retention_in_days = 90

  tags = { Name = "${var.project_name}-api-gateway-logs" }
}

# ── CloudWatch alarm: 4xx errors ─────────────────────────────────────────────
resource "aws_cloudwatch_metric_alarm" "api_4xx" {
  alarm_name          = "${var.project_name}-api-4xx-${var.environment}"
  alarm_description   = "API Gateway 4xx error rate high — may indicate bad requests or authentication issues"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "4XXError"
  namespace           = "AWS/ApiGateway"
  period              = 60
  statistic           = "Sum"
  threshold           = 20
  treat_missing_data  = "notBreaching"

  dimensions = {
    ApiName  = aws_api_gateway_rest_api.orders.name
    StageName = "prod"
  }

  tags = { Name = "${var.project_name}-api-4xx-alarm" }
}
