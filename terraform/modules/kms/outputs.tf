output "raw_data_key_arn" { value = aws_kms_key.raw_data.arn }
output "raw_data_key_id" { value = aws_kms_key.raw_data.key_id }
output "processed_data_key_arn" { value = aws_kms_key.processed_data.arn }
output "processed_data_key_id" { value = aws_kms_key.processed_data.key_id }
output "secrets_key_arn" { value = aws_kms_key.secrets.arn }
output "cloudtrail_key_arn" { value = aws_kms_key.cloudtrail.arn }
output "cloudwatch_logs_key_arn" { value = aws_kms_key.cloudwatch_logs.arn }
