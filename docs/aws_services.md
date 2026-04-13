# AWS Services Used — Justification

| Service | Role | Justification |
|---------|------|---------------|
| **AWS Lambda** | Order processing function | Serverless — no servers to patch, scales to zero, pay per invocation. Python 3.12 runtime. |
| **API Gateway (REST)** | HTTPS ingestion endpoint | Managed TLS termination, request validation, throttling (50 req/s burst), X-Ray tracing. Produces the required `…/prod/orders` URL format. |
| **S3 (raw-orders)** | Raw PII storage | Object storage with versioning, lifecycle transitions (Standard→IA→Glacier), and 7-year retention for legal compliance. KMS CMK encryption. |
| **S3 (processed-orders)** | Anonymized data lake | Hive-partitioned JSON readable directly by Athena without ETL. Separate bucket enforces data zone boundary in IAM. |
| **AWS Glue Data Catalog** | Schema registry for Athena | Defines the `orders_anonymized` table schema with column descriptions. No running servers — purely metadata. |
| **Amazon Athena** | Analytics SQL engine | Serverless SQL over S3. Analysts query anonymized data without accessing raw PII. Results encrypted via KMS. |
| **AWS KMS** | Encryption key management | Customer-managed keys (CMKs) for each data store. Annual automatic rotation. Separation of keys per data tier. |
| **AWS Secrets Manager** | PII pepper storage | HMAC pepper stored encrypted (KMS CMK). IAM policy restricts access to Lambda role only. No automatic rotation (rotation invalidates pseudonymous IDs). |
| **AWS IAM** | Access control | Least-privilege roles per service. Lambda role can only write (not read) raw bucket. Explicit deny policies added as defense-in-depth. |
| **AWS CloudTrail** | Audit logging (GDPR Art. 30) | Records all S3 data events and Lambda invocations. Log file integrity validation enabled. Logs stored in separate bucket with KMS encryption. |
| **AWS CloudWatch** | Observability | Lambda error/duration alarms. API Gateway 4xx/5xx alarms. Structured JSON logs. X-Ray distributed tracing. |
| **Amazon SNS** | Alert notifications | Routes CloudWatch alarm notifications to email/PagerDuty. KMS-encrypted topic. |

## Region Selection: eu-central-1 (Frankfurt, Germany)

Selected for GDPR Articles 44–49 compliance:
- All data remains within the European Economic Area (EEA)
- German data protection law (BDSG) applies as national implementation of GDPR
- AWS Frankfurt has all required services available
- No cross-region replication configured (data stays in single EU region)
