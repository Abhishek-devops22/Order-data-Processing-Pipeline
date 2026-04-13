"""Unit tests for the Lambda order processing handler."""

import hashlib
import hmac
import json
import os
import unittest
from unittest.mock import MagicMock, patch

import pytest

# Set env vars before importing the module
os.environ["RAW_BUCKET_NAME"] = "test-raw-bucket"
os.environ["PROCESSED_BUCKET_NAME"] = "test-processed-bucket"
os.environ["PEPPER_SECRET_ARN"] = "arn:aws:secretsmanager:eu-central-1:123456789:secret:test-pepper"
os.environ["ENVIRONMENT"] = "test"

from function.handler import (
    anonymize_order,
    extract_country,
    pseudonymize_email,
    validate_order,
)

PEPPER = "test-pepper-for-unit-tests"

SAMPLE_ORDER = {
    "order_id": "ORD-2024-001",
    "timestamp": "2024-12-04T10:30:00Z",
    "customer": {
        "email": "customer@example.com",
        "name": "Jane Doe",
        "address": "123 Main St, Berlin, Germany",
    },
    "items": [{"sku": "PROD-001", "quantity": 2, "price": 29.99}],
    "total": 59.98,
    "payment_last4": "4242",
    "currency": "EUR",
}


class TestPseudonymizeEmail:
    def test_produces_hex_output(self):
        result = pseudonymize_email("user@example.com", PEPPER)
        assert all(c in "0123456789abcdef" for c in result)
        assert len(result) == 64  # SHA-256 hex length

    def test_consistent_for_same_email(self):
        r1 = pseudonymize_email("user@example.com", PEPPER)
        r2 = pseudonymize_email("user@example.com", PEPPER)
        assert r1 == r2

    def test_normalizes_case(self):
        lower = pseudonymize_email("user@example.com", PEPPER)
        upper = pseudonymize_email("USER@EXAMPLE.COM", PEPPER)
        assert lower == upper

    def test_different_emails_differ(self):
        r1 = pseudonymize_email("alice@example.com", PEPPER)
        r2 = pseudonymize_email("bob@example.com", PEPPER)
        assert r1 != r2

    def test_different_peppers_differ(self):
        r1 = pseudonymize_email("user@example.com", "pepper-a")
        r2 = pseudonymize_email("user@example.com", "pepper-b")
        assert r1 != r2

    def test_original_email_not_in_output(self):
        result = pseudonymize_email("customer@example.com", PEPPER)
        assert "customer" not in result
        assert "@" not in result


class TestExtractCountry:
    def test_extracts_last_component(self):
        assert extract_country("123 Main St, Berlin, Germany") == "Germany"

    def test_single_value(self):
        assert extract_country("Germany") == "Germany"

    def test_empty_returns_unknown(self):
        assert extract_country("") == "Unknown"

    def test_none_returns_unknown(self):
        assert extract_country(None) == "Unknown"


class TestValidateOrder:
    def test_valid_order_passes(self):
        assert validate_order(SAMPLE_ORDER) == []

    def test_missing_order_id(self):
        order = {**SAMPLE_ORDER, "order_id": None}
        assert any("order_id" in e for e in validate_order(order))

    def test_missing_customer_email(self):
        order = {**SAMPLE_ORDER, "customer": {"name": "Jane", "address": "Berlin"}}
        assert any("email" in e for e in validate_order(order))

    def test_empty_items(self):
        order = {**SAMPLE_ORDER, "items": []}
        assert any("items" in e for e in validate_order(order))

    def test_missing_total(self):
        order = {k: v for k, v in SAMPLE_ORDER.items() if k != "total"}
        assert any("total" in e for e in validate_order(order))


class TestAnonymizeOrder:
    def setup_method(self):
        self.result = anonymize_order(SAMPLE_ORDER, PEPPER)

    def test_order_id_preserved(self):
        assert self.result["order_id"] == "ORD-2024-001"

    def test_email_not_present(self):
        result_str = json.dumps(self.result)
        assert "customer@example.com" not in result_str

    def test_name_not_present(self):
        result_str = json.dumps(self.result)
        assert "Jane Doe" not in result_str
        assert "customer" not in self.result  # No customer sub-object
        assert "name" not in self.result

    def test_full_address_not_present(self):
        result_str = json.dumps(self.result)
        assert "123 Main St" not in result_str

    def test_customer_id_present_and_pseudonymous(self):
        assert "customer_id" in self.result
        assert "@" not in self.result["customer_id"]

    def test_shipping_country_generalized(self):
        assert self.result["shipping_country"] == "Germany"

    def test_items_preserved(self):
        assert self.result["items"] == SAMPLE_ORDER["items"]

    def test_total_preserved(self):
        assert self.result["total"] == 59.98

    def test_payment_last4_preserved(self):
        # Already masked by payment provider — safe for analytics
        assert self.result["payment_last4"] == "4242"

    def test_processed_at_added(self):
        assert "processed_at" in self.result
