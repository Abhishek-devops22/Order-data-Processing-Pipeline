variable "project_name" { type = string }
variable "environment" { type = string }
variable "lambda_role_arn" { type = string }
variable "glue_role_arn" { type = string }
variable "key_deletion_window_days" {
  type    = number
  default = 30
  validation {
    condition     = var.key_deletion_window_days >= 7 && var.key_deletion_window_days <= 30
    error_message = "Key deletion window must be between 7 and 30 days."
  }
}
