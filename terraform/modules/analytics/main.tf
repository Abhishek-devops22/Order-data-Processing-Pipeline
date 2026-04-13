# ── Glue Database ─────────────────────────────────────────────────────────────
resource "aws_glue_catalog_database" "orders" {
  name        = "${replace(var.project_name, "-", "_")}_${var.environment}"
  description = "Anonymized order analytics. Contains no PII. GDPR Article 25 compliant."
}

# ── Glue Table — points to anonymized JSON on S3 ─────────────────────────────
resource "aws_glue_catalog_table" "orders_anonymized" {
  name          = "orders_anonymized"
  database_name = aws_glue_catalog_database.orders.name
  description   = "Anonymized order records. customer.email/name/address suppressed. customer_id = HMAC pseudonym."

  table_type = "EXTERNAL_TABLE"

  parameters = {
    "classification"     = "json"
    "EXTERNAL"           = "TRUE"
    "has_encrypted_data" = "true"

    # Partition Projection — required for Athena engine v3 (Trino).
    # MSCK REPAIR TABLE and ALTER TABLE ADD PARTITION are Hive DDL commands
    # not supported in v3. Projection computes partition paths automatically.
    "projection.enabled"        = "true"
    "projection.year.type"      = "integer"
    "projection.year.range"     = "2024,2030"
    "projection.month.type"     = "integer"
    "projection.month.range"    = "1,12"
    "projection.month.digits"   = "2"
    "projection.day.type"       = "integer"
    "projection.day.range"      = "1,31"
    "projection.day.digits"     = "2"
    "storage.location.template" = "s3://${var.processed_bucket_name}/processed/year=$${year}/month=$${month}/day=$${day}"
  }

  storage_descriptor {
    location      = "s3://${var.processed_bucket_name}/processed/"
    input_format  = "org.apache.hadoop.mapred.TextInputFormat"
    output_format = "org.apache.hadoop.hive.ql.io.HiveIgnoreKeyTextOutputFormat"
    compressed    = false

    ser_de_info {
      name                  = "json-serde"
      serialization_library = "org.openx.data.jsonserde.JsonSerDe"
      parameters = {
        "ignore.malformed.json" = "true"
      }
    }

    columns {
      name    = "order_id"
      type    = "string"
      comment = "Order UUID. Not PII."
    }
    columns {
      name    = "timestamp"
      type    = "string"
      comment = "ISO 8601 UTC order creation timestamp."
    }
    columns {
      name    = "customer_id"
      type    = "string"
      comment = "HMAC-SHA256 pseudonym of customer email. Not reversible without pepper."
    }
    columns {
      name    = "shipping_country"
      type    = "string"
      comment = "Country extracted from address. Generalized — no street/city."
    }
    columns {
      name    = "items"
      type    = "array<struct<sku:string,quantity:int,price:double>>"
      comment = "Order line items."
    }
    columns {
      name    = "item_count"
      type    = "int"
      comment = "Number of line items."
    }
    columns {
      name    = "total"
      type    = "double"
      comment = "Order total value."
    }
    columns {
      name    = "currency"
      type    = "string"
      comment = "ISO 4217 currency code."
    }
    columns {
      name    = "payment_last4"
      type    = "string"
      comment = "Last 4 digits of payment method. Already masked by payment provider."
    }
    columns {
      name    = "processed_at"
      type    = "string"
      comment = "ISO 8601 UTC timestamp when pipeline processed this order."
    }
    columns {
      name    = "pipeline_version"
      type    = "string"
      comment = "Pipeline version that processed this record."
    }
  }

  # Hive-style partitioning for performance and partition-level expiry
  partition_keys {
    name = "year"
    type = "string"
  }
  partition_keys {
    name = "month"
    type = "string"
  }
  partition_keys {
    name = "day"
    type = "string"
  }
}

# ── Athena Workgroup ──────────────────────────────────────────────────────────
resource "aws_athena_workgroup" "orders" {
  name        = "${var.project_name}-${var.environment}"
  description = "Athena workgroup for querying anonymized order analytics."

  configuration {
    enforce_workgroup_configuration    = true
    publish_cloudwatch_metrics_enabled = true

    result_configuration {
      output_location = "s3://${var.athena_results_bucket}/athena-results/"

      encryption_configuration {
        encryption_option = "SSE_KMS"
        kms_key_arn       = var.processed_kms_key_arn
      }
    }

    engine_version {
      selected_engine_version = "Athena engine version 3"
    }
  }

  tags = {
    Name = "${var.project_name}-athena-${var.environment}"
  }
}
