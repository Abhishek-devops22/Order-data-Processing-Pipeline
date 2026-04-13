#!/usr/bin/env python3
"""
GDPR Article 17 — Right to Erasure.

Deletes all data associated with a customer email from:
  1. S3 raw bucket (raw objects with PII)
  2. S3 processed bucket (anonymized objects keyed by customer_id HMAC)

Always run with --dry-run first.

Usage:
    python scripts/gdpr_erasure.py \\
        --email customer@example.com \\
        --raw-bucket yepoda-raw-orders-dev-123456789 \\
        --processed-bucket yepoda-processed-orders-dev-123456789 \\
        --pepper-secret-arn arn:aws:secretsmanager:eu-central-1:... \\
        --region eu-central-1 \\
        --dry-run
"""

import argparse
import hashlib
import hmac
import json
import logging
import sys
from datetime import datetime, timezone

import boto3

logging.basicConfig(level=logging.INFO, format="%(asctime)s [%(levelname)s] %(message)s")
logger = logging.getLogger(__name__)


def get_pepper(secret_arn: str, region: str) -> str:
    client = boto3.client("secretsmanager", region_name=region)
    response = client.get_secret_value(SecretId=secret_arn)
    return response["SecretString"]


def compute_customer_id(email: str, pepper: str) -> str:
    """Reproduce the same HMAC as the Lambda function."""
    normalized = email.lower().strip().encode("utf-8")
    return hmac.new(pepper.encode("utf-8"), normalized, hashlib.sha256).hexdigest()


def find_and_delete_raw_objects(s3, bucket: str, email: str, dry_run: bool) -> int:
    """
    Raw objects are stored by order_id, not email.
    We must download the object to check if it belongs to this customer.
    For large datasets, use Athena to look up order_ids first.
    """
    paginator = s3.get_paginator("list_objects_v2")
    deleted = 0

    for page in paginator.paginate(Bucket=bucket, Prefix="raw/"):
        for obj in page.get("Contents", []):
            key = obj["Key"]
            try:
                response = s3.get_object(Bucket=bucket, Key=key)
                order = json.loads(response["Body"].read())
                if order.get("customer", {}).get("email", "").lower().strip() == email.lower().strip():
                    if dry_run:
                        logger.info("[DRY RUN] Would delete raw object: s3://%s/%s", bucket, key)
                    else:
                        s3.delete_object(Bucket=bucket, Key=key)
                        logger.info("Deleted raw object: s3://%s/%s", bucket, key)
                    deleted += 1
            except Exception as exc:
                logger.warning("Could not process %s: %s", key, str(exc))

    return deleted


def find_and_delete_processed_objects(s3, bucket: str, customer_id: str, dry_run: bool) -> int:
    """
    Processed objects contain customer_id (HMAC). Scan and match.
    """
    paginator = s3.get_paginator("list_objects_v2")
    deleted = 0

    for page in paginator.paginate(Bucket=bucket, Prefix="processed/"):
        for obj in page.get("Contents", []):
            key = obj["Key"]
            try:
                response = s3.get_object(Bucket=bucket, Key=key)
                record = json.loads(response["Body"].read())
                if record.get("customer_id") == customer_id:
                    if dry_run:
                        logger.info("[DRY RUN] Would delete processed object: s3://%s/%s", bucket, key)
                    else:
                        s3.delete_object(Bucket=bucket, Key=key)
                        logger.info("Deleted processed object: s3://%s/%s", bucket, key)
                    deleted += 1
            except Exception as exc:
                logger.warning("Could not process %s: %s", key, str(exc))

    return deleted


def main():
    parser = argparse.ArgumentParser(description="GDPR Article 17 Erasure")
    parser.add_argument("--email", required=True)
    parser.add_argument("--raw-bucket", required=True)
    parser.add_argument("--processed-bucket", required=True)
    parser.add_argument("--pepper-secret-arn", required=True)
    parser.add_argument("--region", default="eu-central-1")
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()

    if args.dry_run:
        logger.info("=== DRY RUN — no data will be deleted ===")

    logger.info("Fetching pepper from Secrets Manager...")
    pepper = get_pepper(args.pepper_secret_arn, args.region)
    customer_id = compute_customer_id(args.email, pepper)
    logger.info("Customer pseudonymous ID: %s...", customer_id[:12])

    s3 = boto3.client("s3", region_name=args.region)

    # 1. Delete raw objects (contain PII email in the JSON body)
    raw_deleted = find_and_delete_raw_objects(s3, args.raw_bucket, args.email, args.dry_run)
    logger.info("Raw objects %s: %d", "would delete" if args.dry_run else "deleted", raw_deleted)

    # 2. Delete processed objects (matched by customer_id HMAC)
    proc_deleted = find_and_delete_processed_objects(s3, args.processed_bucket, customer_id, args.dry_run)
    logger.info("Processed objects %s: %d", "would delete" if args.dry_run else "deleted", proc_deleted)

    if args.dry_run:
        logger.info("=== DRY RUN COMPLETE — rerun without --dry-run to execute ===")
        logger.info("Total objects that would be deleted: %d", raw_deleted + proc_deleted)
    else:
        logger.info("Erasure complete. Total objects deleted: %d", raw_deleted + proc_deleted)
        logger.info("CloudTrail will have recorded this operation as the audit trail (GDPR Art. 17(3)(e)).")


if __name__ == "__main__":
    main()
