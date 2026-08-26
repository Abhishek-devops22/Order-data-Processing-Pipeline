# Architecture — GDPR-Compliant Order Data Processing Pipeline (AWS)

## Data Flow Diagram

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                        AWS eu-central-1 (Frankfurt)                         │
│                                                                             │
│  E-commerce        HTTPS (TLS 1.2+)                                         │
│  Webhook  ────────────────────────►  API Gateway (REST)                     │
│                                        │  POST /prod/orders                 │
│                                        │  • Schema validation               │
│                                        │  • Rate limiting (50 req/s)        │
│                                        │  • X-Ray tracing                   │
│                                        ▼                                    │
│                                   Lambda Function                           │
│                                   order-processor                           │
│                                        │                                    │
│                          ┌─────────────┼──────────────┐                     │
│                          │             │              │                     │
│                          ▼             ▼              ▼                     │
│                   Secrets Manager    Step 1:        Step 2:                 │
│                   (PII Pepper)    Store RAW      Anonymize PII              │
│                          │        with PII      + Store processed           │
│                          │            │              │                      │
│                          │            ▼              ▼                      │
│                          │     ┌──────────┐   ┌──────────────┐              │
│                          │     │  S3 Raw  │   │ S3 Processed │              │
│                          │     │  Bucket  │   │   Bucket     │              │
│                          │     │  (PII)   │   │ (Anonymized) │              │
│                          │     │  KMS CMK │   │   KMS CMK    │              │
│                          │     │ 7yr ret. │   │  Athena ◄────┼────► BI      │
│                          │     └──────────┘   └──────────────┘              │
│                          │                                                  │
│                    ┌─────┘                                                  │
│                    ▼                                                        │
│             CloudTrail ──► CloudTrail S3 Bucket (audit logs, encrypted)     │
│             CloudWatch ──► Dashboards + Alarms + Log Groups                 │
│                                                                             │
│  ─────────────── IAM / KMS / Secrets Manager ─────────────────────────      │
│  All API calls authenticated via IAM. All data encrypted with CMKs.         │
└─────────────────────────────────────────────────────────────────────────────┘
```

## PII Anonymization Detail

```
Input Order (with PII)              Processed Record (no PII)
─────────────────────               ──────────────────────────
order_id: "ORD-2024-001"     →      order_id: "ORD-2024-001"       ✓ kept
customer.email: "a@b.com"    →      customer_id: "a1b2c3..."       ✓ HMAC pseudonym
customer.name: "Jane Doe"    →      (suppressed)                   ✗ removed
customer.address: "123..."   →      shipping_country: "Germany"    ✓ generalized
items: [...]                 →      items: [...]                   ✓ kept
total: 59.98                 →      total: 59.98                   ✓ kept
payment_last4: "4242"        →      payment_last4: "4242"          ✓ already masked
```

## Security Layers

```
Layer 1 — Transport    HTTPS/TLS 1.2+ enforced on all endpoints
Layer 2 — Auth         IAM roles with least-privilege; no public S3
Layer 3 — Network      Bucket policies deny non-TLS; deny non-Lambda writes to raw
Layer 4 — Encryption   AWS KMS CMKs on all data stores (S3, Secrets Manager)
Layer 5 — Application  HMAC-SHA256 pseudonymization + field suppression
Layer 6 — Audit        CloudTrail logs all data events; CloudWatch alarms
```

## Data Zones

| Zone      | Service                | Contains PII      | Access                        |
|------     |------------------------|-------------------|-------------------------------|
| Raw       | S3 `raw-orders-*`      | Yes               | Lambda write-only             |
| Processed | S3 `processed-orders-*`| No                | Lambda write, Glue/Athena read|
| Analytics | Glue + Athena          | No                | BI tools (read-only)          |
| Audit     | CloudTrail S3          | No                | Security team only            |
| Secrets | Secrets Manager          | Cryptographic material | Lambda read-only         |
