"""
Order Processing Lambda — GDPR-compliant data pipeline.

Flow:
  API Gateway POST /orders
    → validate input
    → store raw order (with PII) to raw S3 bucket (encrypted, restricted)
    → pseudonymize PII fields
    → store anonymized record to processed S3 bucket (Athena-queryable)
    → return 200 with confirmation

PII handling:
  customer.email   → customer_id  = HMAC-SHA256(email, pepper)  [pseudonymous, consistent]
  customer.name    → suppressed   (not stored anywhere in processed data)
  customer.address → shipping_country extracted, full address suppressed
  payment_last4    → retained     (already masked by payment provider, analytics-safe)
"""

import hashlib
import hmac
import json
import logging
import os
import re
import uuid
from datetime import datetime, timezone

import boto3
from botocore.exceptions import ClientError

# ── Logging ──────────────────────────────────────────────────────────────────
logger = logging.getLogger()
logger.setLevel(logging.INFO)

# ── AWS clients (reused across warm invocations) ──────────────────────────────
s3 = boto3.client("s3")
secretsmanager = boto3.client("secretsmanager")

# ── Configuration from environment variables (set by Terraform) ───────────────
RAW_BUCKET = os.environ["RAW_BUCKET_NAME"]
PROCESSED_BUCKET = os.environ["PROCESSED_BUCKET_NAME"]
PEPPER_SECRET_ARN = os.environ["PEPPER_SECRET_ARN"]
ENVIRONMENT = os.environ.get("ENVIRONMENT", "dev")

# Module-level pepper cache — fetched once per Lambda container lifetime
_pepper_cache: str | None = None


# ── Helpers ───────────────────────────────────────────────────────────────────

def get_pepper() -> str:
    """Fetch the HMAC pepper from Secrets Manager. Cached per container."""
    global _pepper_cache
    if _pepper_cache is None:
        try:
            response = secretsmanager.get_secret_value(SecretId=PEPPER_SECRET_ARN)
            _pepper_cache = response["SecretString"]
        except ClientError as exc:
            logger.error("Failed to fetch pepper from Secrets Manager: %s", exc.response["Error"]["Code"])
            raise RuntimeError("Cannot retrieve cryptographic material") from exc
    return _pepper_cache


def pseudonymize_email(email: str, pepper: str) -> str:
    """
    HMAC-SHA256(normalised_email, pepper) → hex string.

    Consistent: same email always produces same customer_id.
    Not reversible without the pepper (stored in Secrets Manager).
    """
    normalized = email.lower().strip().encode("utf-8")
    return hmac.new(pepper.encode("utf-8"), normalized, hashlib.sha256).hexdigest()


def extract_country(address: str) -> str:
    """
    Extract country from a free-text address string.
    Returns the last comma-separated token (common convention: "..., Country").
    Falls back to "Unknown" if parsing fails.
    """
    if not address:
        return "Unknown"
    parts = [p.strip() for p in address.split(",")]
    return parts[-1] if parts else "Unknown"


def validate_order(order: dict) -> list[str]:
    """Return a list of validation error messages. Empty list = valid."""
    errors = []
    if not order.get("order_id"):
        errors.append("missing field: order_id")
    if not order.get("timestamp"):
        errors.append("missing field: timestamp")
    customer = order.get("customer", {})
    if not customer.get("email"):
        errors.append("missing field: customer.email")
    if not customer.get("name"):
        errors.append("missing field: customer.name")
    if not isinstance(order.get("items"), list) or len(order["items"]) == 0:
        errors.append("items must be a non-empty list")
    if order.get("total") is None:
        errors.append("missing field: total")
    return errors


def build_raw_s3_key(order_id: str, now: datetime) -> str:
    """Hive-partitioned path for raw data. Uses order_id, not email, as key."""
    return (
        f"raw/year={now.year}/month={now.month:02d}/day={now.day:02d}"
        f"/{order_id}.json"
    )


def build_processed_s3_key(order_id: str, now: datetime) -> str:
    """Hive-partitioned path for processed/anonymized data (Athena-queryable)."""
    return (
        f"processed/year={now.year}/month={now.month:02d}/day={now.day:02d}"
        f"/{order_id}.json"
    )


def anonymize_order(order: dict, pepper: str) -> dict:
    """
    Transform an order dict into an anonymized analytics record.

    Fields suppressed (not present in output):
      customer.name, customer.address (full), customer.email

    Fields pseudonymized:
      customer.email → customer_id (HMAC)

    Fields generalized:
      customer.address → shipping_country (country only)

    Fields retained as-is (non-PII or already masked):
      order_id, timestamp, items, total, currency, payment_last4
    """
    customer = order.get("customer", {})
    return {
        "order_id": order["order_id"],
        "timestamp": order["timestamp"],
        "customer_id": pseudonymize_email(customer.get("email", ""), pepper),
        "shipping_country": extract_country(customer.get("address", "")),
        "items": order.get("items", []),
        "item_count": len(order.get("items", [])),
        "total": order.get("total"),
        "currency": order.get("currency", "EUR"),
        "payment_last4": order.get("payment_last4"),   # Already masked by payment provider
        "processed_at": datetime.now(tz=timezone.utc).isoformat(),
        "pipeline_version": "1.0",
    }


def http_response(status_code: int, body: dict) -> dict:
    return {
        "statusCode": status_code,
        "headers": {
            "Content-Type": "application/json",
            "X-Content-Type-Options": "nosniff",
            "Strict-Transport-Security": "max-age=31536000; includeSubDomains",
        },
        "body": json.dumps(body),
    }


# ── Lambda handler ────────────────────────────────────────────────────────────

def lambda_handler(event: dict, context) -> dict:
    """
    Entry point for API Gateway → Lambda.
    Accepts POST /orders with the Yepoda order JSON format.
    """
    processing_id = str(uuid.uuid4())
    now = datetime.now(tz=timezone.utc)

    logger.info(
        "Order processing started",
        extra={"processing_id": processing_id, "environment": ENVIRONMENT},
    )

    # ── 1. Parse request body ─────────────────────────────────────────────────
    try:
        body = event.get("body") or "{}"
        if isinstance(body, str):
            order = json.loads(body)
        else:
            order = body
    except json.JSONDecodeError as exc:
        logger.warning("Invalid JSON in request body: %s", str(exc))
        return http_response(400, {"error": "invalid_json", "message": str(exc)})

    # ── 2. Validate ───────────────────────────────────────────────────────────
    errors = validate_order(order)
    if errors:
        logger.warning("Order validation failed: %s", errors)
        return http_response(400, {"error": "validation_failed", "details": errors})

    order_id = order["order_id"]

    # ── 3. Fetch GDPR pepper ──────────────────────────────────────────────────
    try:
        pepper = get_pepper()
    except RuntimeError as exc:
        logger.error("Pepper fetch failed for order %s: %s", order_id, str(exc))
        return http_response(500, {"error": "internal_error", "processing_id": processing_id})

    # ── 4. Store raw order (with PII) to restricted raw bucket ───────────────
    raw_key = build_raw_s3_key(order_id, now)
    try:
        s3.put_object(
            Bucket=RAW_BUCKET,
            Key=raw_key,
            Body=json.dumps(order, default=str).encode("utf-8"),
            ContentType="application/json",
            # Server-side encryption with KMS key (bucket default enforces this)
            Metadata={
                "processing-id": processing_id,
                "data-classification": "PII",
                "gdpr-relevant": "true",
            },
        )
        logger.info("Raw order stored: s3://%s/%s", RAW_BUCKET, raw_key)
    except ClientError as exc:
        logger.error("Failed to store raw order %s: %s", order_id, exc.response["Error"]["Code"])
        return http_response(500, {"error": "storage_failed", "processing_id": processing_id})

    # ── 5. Anonymize PII ──────────────────────────────────────────────────────
    anonymized = anonymize_order(order, pepper)

    # ── 6. Store anonymized record to processed bucket (Athena-queryable) ─────
    processed_key = build_processed_s3_key(order_id, now)
    try:
        s3.put_object(
            Bucket=PROCESSED_BUCKET,
            Key=processed_key,
            Body=json.dumps(anonymized, default=str).encode("utf-8"),
            ContentType="application/json",
            Metadata={
                "processing-id": processing_id,
                "data-classification": "anonymized",
                "pii-present": "false",
            },
        )
        logger.info("Anonymized order stored: s3://%s/%s", PROCESSED_BUCKET, processed_key)
    except ClientError as exc:
        logger.error("Failed to store processed order %s: %s", order_id, exc.response["Error"]["Code"])
        return http_response(500, {"error": "storage_failed", "processing_id": processing_id})

    # ── 7. Return success ─────────────────────────────────────────────────────
    logger.info(
        "Order processed successfully",
        extra={"order_id": order_id, "processing_id": processing_id},
    )
    return http_response(
        200,
        {
            "status": "processed",
            "order_id": order_id,
            "processing_id": processing_id,
            "message": "Order anonymized and stored successfully",
            "pii_suppressed": ["customer.name", "customer.address", "customer.email"],
        },
    )
