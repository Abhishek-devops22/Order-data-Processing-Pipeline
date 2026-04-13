# ── Primary outputs (shown after terraform apply) ─────────────────────────────

output "orders_endpoint" {
  description = "HTTPS endpoint for POST /orders — use this in the curl test"
  value       = module.api_gateway.orders_endpoint
}

output "api_gateway_base_url" {
  description = "API Gateway base URL (format: https://{id}.execute-api.eu-central-1.amazonaws.com/prod)"
  value       = module.api_gateway.invoke_url
}

output "lambda_function_name" {
  description = "Lambda function name"
  value       = module.lambda.function_name
}

output "raw_orders_bucket" {
  description = "S3 bucket for raw orders (contains PII — restricted access)"
  value       = module.storage.raw_bucket_id
}

output "processed_orders_bucket" {
  description = "S3 bucket for anonymized orders (Athena-queryable)"
  value       = module.storage.processed_bucket_id
}

output "athena_query_command" {
  description = "Sample Athena query to verify processed order data"
  value       = <<-EOQ
    Run in AWS Console → Athena, workgroup '${module.analytics.athena_workgroup_name}':

    SELECT order_id, customer_id, shipping_country, total, currency, processed_at
    FROM "${module.analytics.glue_database_name}"."${module.analytics.glue_table_name}"
    LIMIT 10;
  EOQ
}

output "curl_test_command" {
  description = "Copy-paste curl command for the live endpoint test"
  value       = <<-EOC
    curl -s -X POST ${module.api_gateway.orders_endpoint} \
      -H "Content-Type: application/json" \
      -d '{
        "order_id": "ORD-2024-001",
        "timestamp": "2024-12-04T10:30:00Z",
        "customer": {
          "email": "customer@example.com",
          "name": "Jane Doe",
          "address": "123 Main St, Berlin, Germany"
        },
        "items": [{"sku": "PROD-001", "quantity": 2, "price": 29.99}],
        "total": 59.98,
        "payment_last4": "4242",
        "currency": "EUR"
      }' | python3 -m json.tool
  EOC
}

output "glue_database_name" {
  description = "Glue database name for Athena queries"
  value       = module.analytics.glue_database_name
}

output "glue_table_name" {
  description = "Glue table name for anonymized orders"
  value       = module.analytics.glue_table_name
}

output "aws_region" {
  description = "AWS region where all resources are deployed"
  value       = var.aws_region
}
