variable "aws_region" {
  description = "AWS region. eu-central-1 (Frankfurt) selected for GDPR data residency within EU."
  type        = string
  default     = "eu-central-1"
  validation {
    condition     = can(regex("^eu-", var.aws_region))
    error_message = "Region must be in Europe (eu-*) for GDPR data residency compliance."
  }
}

variable "project_name" {
  description = "Project name used as prefix for all resource names."
  type        = string
  default     = "yepoda"
  validation {
    condition     = can(regex("^[a-z0-9-]+$", var.project_name))
    error_message = "Project name must be lowercase alphanumeric with hyphens only."
  }
}

variable "environment" {
  description = "Deployment environment."
  type        = string
  default     = "dev"
  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "Must be dev, staging, or prod."
  }
}

variable "raw_data_retention_days" {
  description = "Days to retain raw PII data. Minimum 365 for legal/tax compliance."
  type        = number
  default     = 2555 # 7 years
  validation {
    condition     = var.raw_data_retention_days >= 365
    error_message = "Raw data retention must be at least 365 days."
  }
}

variable "processed_data_retention_days" {
  description = "Days to retain processed (anonymized) data."
  type        = number
  default     = 2555
}

variable "lambda_memory_mb" {
  description = "Lambda memory in MB."
  type        = number
  default     = 256
}

variable "lambda_timeout_seconds" {
  description = "Lambda timeout in seconds."
  type        = number
  default     = 30
}

variable "alert_email" {
  description = "Email address for CloudWatch alarm notifications."
  type        = string
  default     = ""
}
