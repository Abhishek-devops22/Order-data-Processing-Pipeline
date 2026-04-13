output "raw_bucket_id" { value = aws_s3_bucket.raw.id }
output "raw_bucket_arn" { value = aws_s3_bucket.raw.arn }
output "processed_bucket_id" { value = aws_s3_bucket.processed.id }
output "processed_bucket_arn" { value = aws_s3_bucket.processed.arn }
output "processed_bucket_name" { value = aws_s3_bucket.processed.id }
output "athena_results_bucket" { value = aws_s3_bucket.athena_results.id }
output "cloudtrail_bucket_id" { value = aws_s3_bucket.cloudtrail.id }
output "cloudtrail_bucket_arn" { value = aws_s3_bucket.cloudtrail.arn }
