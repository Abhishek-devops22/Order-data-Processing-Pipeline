variable "function_name" { type = string }
variable "environment" { type = string }
variable "function_zip_path" { type = string }
variable "function_zip_hash" { type = string }
variable "lambda_role_arn" { type = string }
variable "raw_bucket_name" { type = string }
variable "processed_bucket_name" { type = string }
variable "pepper_secret_arn" { type = string }
variable "cloudwatch_kms_key_arn" { type = string }
variable "memory_mb" {
    type = number
    default = 256
    }
variable "timeout_seconds" { 
    type = number
     default = 30 
     }
variable "alarm_sns_arns" { 
    type = list(string)
     default = [] 
    }

