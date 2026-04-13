output "api_id" { value = aws_api_gateway_rest_api.orders.id }
output "stage_name" { value = aws_api_gateway_stage.prod.stage_name }
output "invoke_url" {
  description = "Base URL of the API Gateway (without resource path)"
  value       = aws_api_gateway_stage.prod.invoke_url
}
output "orders_endpoint" {
  description = "Full HTTPS endpoint for POST /orders"
  value       = "${aws_api_gateway_stage.prod.invoke_url}/orders"
}
