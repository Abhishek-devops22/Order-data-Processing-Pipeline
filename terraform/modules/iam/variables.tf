variable "project_name" { type = string }
variable "environment" { type = string }
variable "raw_bucket_arn" { type = string }
variable "processed_bucket_arn" { type = string }
variable "pepper_secret_arn" { type = string }
variable "kms_key_arns" { type = list(string) }
variable "processed_data_key_arn" { type = string }

# Placeholder role IDs/ARNs created in root main.tf to break the KMS circular dependency
variable "lambda_exec_role_id" { type = string }
variable "lambda_exec_role_arn" { type = string }
variable "glue_role_id" { type = string }
variable "glue_role_arn" { type = string }
