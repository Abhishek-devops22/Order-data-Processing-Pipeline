# GDPR Compliance Report

**Project:** Yepoda Order Processing Pipeline (AWS)
**Data Controller:** Yepoda GmbH
**Processing Purpose:** E-commerce order management and analytics
**Technical Implementation:** AWS Lambda + S3 + Athena, eu-central-1 (Frankfurt)

---

## 1. Lawful Basis and Consent (Articles 6 & 7)

Orders are processed under Article 6(1)(b) — *performance of a contract* — as processing
is necessary to fulfil the customer's purchase. The `consent_version` field is required on
every incoming order, ensuring the pipeline can only process orders where the customer has
acknowledged the privacy policy. This field is retained in the anonymized analytics record,
providing an audit trail of which policy version applied at the time of processing.

## 2. Data Minimisation and Purpose Limitation (Articles 5 & 25)

The pipeline applies **privacy by design** through strict data separation:

- `customer.name` is **suppressed entirely** — it serves no analytics purpose
- `customer.email` is **pseudonymized** using HMAC-SHA256 with a secret pepper stored in
  AWS Secrets Manager, producing a consistent `customer_id` that enables cross-order
  analytics without storing the email address
- `customer.address` is **generalized** to country level only — the street address and city
  are discarded before writing to the analytics store
- `payment_last4` is retained as it is already masked by the payment provider and has
  legitimate fraud analytics value

The **processed S3 bucket schema** (enforced via Glue table definition) contains no PII
columns, making accidental PII storage structurally impossible.

## 3. Storage Limitation and Deletion (Article 5(1)(e))

Two retention mechanisms are in place:

1. **Raw S3 bucket lifecycle policy**: objects transition to S3-IA after 90 days, Glacier
   after 365 days, and are **automatically deleted after 2,555 days (7 years)**. The 7-year
   period satisfies EU commercial record-keeping obligations (§ 257 HGB) while ensuring data
   is not held beyond legal necessity.

2. **Right to Erasure script**: a `scripts/gdpr_erasure.py` utility (documented in README)
   accepts a customer email, recomputes the pseudonymous ID, and deletes matching records
   from both the raw S3 bucket and the processed analytics store, followed by writing an
   erasure audit event to CloudTrail.

## 4. Security of Processing (Article 32)

Security is implemented in layers:

- **Encryption at rest**: all S3 buckets, Secrets Manager secrets, and CloudWatch logs use
  AWS KMS customer-managed keys (CMKs) with automatic annual rotation
- **Encryption in transit**: S3 bucket policies include an explicit `Deny` for non-TLS
  requests; API Gateway enforces HTTPS-only
- **Least-privilege IAM**: the Lambda role can only *write* to the raw bucket (no read-back
  of PII), *write* to the processed bucket, and *read* the single pepper secret. An explicit
  `Deny` on raw bucket reads provides defense-in-depth even if the `Allow` policy is misconfigured
- **Audit trail**: AWS CloudTrail logs all S3 data events (reads and writes) on both buckets
  and all Lambda invocations, satisfying Article 30 records-of-processing requirements

## 5. Data Transfers (Articles 44–49)

All AWS resources are deployed exclusively in `eu-central-1` (Frankfurt, Germany). No
cross-region replication is configured. This ensures personal data remains within the EEA
and no adequacy decision or transfer mechanism (SCCs) is required.

## 6. Risks and Mitigations

| Risk | Mitigation |
|------|-----------|
| PII leakage into analytics store | Schema enforced by Glue table; no PII columns defined |
| Pepper compromise enabling de-pseudonymization | Pepper in Secrets Manager with IAM deny-all policy except Lambda role |
| Unauthorized raw bucket access | Bucket policy + IAM deny-read on Lambda role + CloudTrail alarm |
| Data leaving EU | Region locked to eu-central-1; no replication configured |
| Audit log tampering | CloudTrail log file integrity validation enabled |
