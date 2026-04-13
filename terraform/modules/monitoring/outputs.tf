output "sns_topic_arn" { value = aws_sns_topic.alerts.arn }
output "cloudtrail_arn" { value = aws_cloudtrail.pipeline.arn }
