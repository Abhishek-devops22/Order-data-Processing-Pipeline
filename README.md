# Order Data Processing Pipeline — AWS

GDPR-compliant serverless data pipeline on AWS that receives e-commerce orders,
pseudonymizes PII, stores raw data securely, and makes anonymized data queryable via Athena.

## Architecture

```
E-commerce Webhook
        │ HTTPS POST /prod/orders
        ▼
┌───────────────────┐
│   API Gateway     │  Schema validation, throttling, TLS termination
│   REST API        │
└────────┬──────────┘
         │ AWS_PROXY
         ▼
┌───────────────────┐     ┌─────────────────────────┐
│   Lambda          │────►│  S3: raw-orders-*       │  PII intact, KMS CMK,
│   (Python 3.12)   │     │  (restricted write-only)│  7-year lifecycle
│                   │     └─────────────────────────┘
│  1. Validate      │
│  2. Store raw     │     ┌─────────────────────────┐
│  3. Anonymize PII │────►│  S3: processed-orders-* │  No PII, Athena-queryable
│  4. Store anon.   │     │  Glue + Athena          │  Hive-partitioned JSON
└───────────────────┘     └─────────────────────────┘
         │
         ▼
Secrets Manager (HMAC pepper) │ KMS CMKs (5 keys) │ CloudTrail │ CloudWatch
```

**PII handling:**
| Field | Raw bucket | Processed bucket |
|-------|-----------|-----------------|
| `customer.email` | Stored (PII) | `customer_id` = HMAC-SHA256(email, pepper) |
| `customer.name` | Stored (PII) | **Suppressed** |
| `customer.address` | Stored (PII) | `shipping_country` (country only) |
| `payment_last4` | Stored | Stored (already masked) |

---

## Prerequisites

- [AWS CLI v2](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html) configured with admin credentials
- [Terraform >= 1.6](https://www.terraform.io/downloads)
- Python 3.12 (for running tests locally)
- AWS account in `eu-central-1` region

```bash
aws configure
# AWS Access Key ID: ...
# AWS Secret Access Key: ...
# Default region name: eu-central-1
# Default output format: json
```

---

## Step-by-Step Deployment

### 1. Clone the repository

```bash
git clone https://github.com/Abhishek-devops22/Order-data-Processing-Pipeline.git
cd Order-data-Processing-Pipeline
```

### 2. Create the Terraform state bucket (one-time)

This bucket stores Terraform state remotely. Create it once per AWS account before the first `terraform init`.

```bash
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
STATE_BUCKET="yepoda-project-tfstate"

aws s3api create-bucket \
  --bucket "$STATE_BUCKET" \
  --region eu-central-1 \
  --create-bucket-configuration LocationConstraint=eu-central-1

aws s3api put-bucket-versioning \
  --bucket "$STATE_BUCKET" \
  --versioning-configuration Status=Enabled

aws s3api put-bucket-encryption \
  --bucket "$STATE_BUCKET" \
  --server-side-encryption-configuration \
  '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'

aws s3api put-public-access-block \
  --bucket "$STATE_BUCKET" \
  --public-access-block-configuration \
  "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"

echo "State bucket ready: $STATE_BUCKET"
```

### 3. Configure Terraform variables

```bash
cd terraform
```

Edit `terraform.tfvars`:
```hcl
aws_region   = "eu-central-1"
project_name = "yepoda"
environment  = "dev"

raw_data_retention_days       = 2555  # 7 years (GDPR minimum for financial records)
processed_data_retention_days = 2555

lambda_memory_mb       = 256
lambda_timeout_seconds = 30

# Optional: email for CloudWatch alarm notifications
alert_email = ""
```

> **Note:** `aws_region` must be an EU region (`eu-*`). The variable has a validation rule enforcing this for GDPR data residency.

### 4. Initialize Terraform

```bash
terraform init \
  -backend-config="bucket=yepoda-project-tfstate" \
  -backend-config="key=order-pipeline/terraform.tfstate" \
  -backend-config="region=eu-central-1"
```

### 5. Plan and Apply

```bash
terraform plan -var-file=terraform.tfvars
terraform apply -var-file=terraform.tfvars
```

After `apply` completes (~3–5 minutes), Terraform prints the outputs:
```
orders_endpoint          = "https://xxxx.execute-api.eu-central-1.amazonaws.com/prod/orders"
curl_test_command        = (copy-paste ready curl command)
athena_query_command     = (copy-paste ready SQL query)
lambda_function_name     = "yepoda-order-processor-dev"
raw_orders_bucket        = "yepoda-raw-orders-dev-<account-id>"
processed_orders_bucket  = "yepoda-processed-orders-dev-<account-id>"
```

---

## Live Endpoint Test

Copy the `curl_test_command` from Terraform outputs, or run:

```bash
ENDPOINT=$(terraform output -raw orders_endpoint)

curl -s -X POST "$ENDPOINT" \
  -H "Content-Type: application/json" \
  -d '{
    "order_id": "ORD-2024-001",
    "timestamp": "2024-12-04T10:30:00Z",
    "customer": {
      "email": "customer@example.com",
      "name": "Jane Doe",
      "address": "123 Main St, Berlin, Germany"
    },
    "items": [{"sku": "PROD-001", "quantity": 2, "price": 29.99}],
    "total": 59.98,
    "payment_last4": "4242",
    "currency": "EUR"
  }' | python3 -m json.tool
```

**Expected response (HTTP 200):**
```json
{
  "status": "processed",
  "order_id": "ORD-2024-001",
  "processing_id": "uuid-here",
  "message": "Order anonymized and stored successfully",
  "pii_suppressed": ["customer.name", "customer.address", "customer.email"]
}
```

---

## Verify Data in Athena

1. Go to **AWS Console → Athena**
2. Select workgroup: `yepoda-dev` (format: `<project_name>-<environment>`)
3. Run:

```sql
SELECT order_id, customer_id, shipping_country, total, currency, processed_at
FROM "yepoda_dev"."orders_anonymized"
LIMIT 10;
```

> **Note:** After the first order is processed, wait ~30 seconds for S3 consistency, then
> run the Athena query. If you see 0 rows, run:
> ```sql
> MSCK REPAIR TABLE "yepoda_dev"."orders_anonymized";
> ```
> This discovers new Hive partitions (year/month/day) added by Lambda.

---

## Running Unit Tests

```bash
cd Order-data-Processing-Pipeline

# Install test dependencies
pip install pytest boto3 moto

# Run tests
python -m pytest function/tests/ -v
```

---

## GDPR Right to Erasure

Get the pepper secret ARN first (it is not a root Terraform output — retrieve it from AWS):

```bash
PEPPER_SECRET_ARN=$(aws secretsmanager describe-secret \
  --secret-id yepoda/pii-pepper/dev \
  --query ARN --output text)

RAW_BUCKET=$(cd terraform && terraform output -raw raw_orders_bucket)
PROCESSED_BUCKET=$(cd terraform && terraform output -raw processed_orders_bucket)
```

```bash
# Dry run first (no data deleted)
python scripts/gdpr_erasure.py \
  --email customer@example.com \
  --raw-bucket "$RAW_BUCKET" \
  --processed-bucket "$PROCESSED_BUCKET" \
  --pepper-secret-arn "$PEPPER_SECRET_ARN" \
  --region eu-central-1 \
  --dry-run

# Execute erasure (remove --dry-run)
python scripts/gdpr_erasure.py \
  --email customer@example.com \
  --raw-bucket "$RAW_BUCKET" \
  --processed-bucket "$PROCESSED_BUCKET" \
  --pepper-secret-arn "$PEPPER_SECRET_ARN" \
  --region eu-central-1
```

---

## Destroy Infrastructure

```bash
cd terraform
terraform destroy -var-file=terraform.tfvars
```

> **Important:** KMS keys have a 7-day deletion window — they are scheduled for deletion, not
> immediately removed. The Secrets Manager secret is configured with
> `recovery_window_in_days = 0` so it is deleted immediately on destroy, allowing a clean
> re-apply without name conflicts.

---

## Troubleshooting

### If `terraform apply` fails mid-way

A partial apply leaves some resources in AWS but not in Terraform state. **Do not re-run apply directly** — it will hit 409/conflict errors trying to create resources that already exist.

The correct recovery steps:

```bash
# 1. Destroy what Terraform knows about
terraform destroy -var-file=terraform.tfvars

# 2. Check for orphaned resources not tracked in state
aws iam list-roles --query "Roles[?contains(RoleName, 'yepoda')].RoleName" --output text
aws kms list-aliases --query "Aliases[?contains(AliasName, 'yepoda')].AliasName" --output text
aws secretsmanager list-secrets --query "SecretList[?contains(Name, 'yepoda')].Name" --output text

# 3. Manually delete any orphaned resources found above, then fresh apply
terraform apply -var-file=terraform.tfvars
```

### Secrets Manager name conflict

If you see `InvalidRequestException: secret is already scheduled for deletion`, the secret is in a 7-day recovery window from a previous destroy. This config sets `recovery_window_in_days = 0` to prevent this, but if you hit it with an older deployment:

```bash
aws secretsmanager delete-secret \
  --secret-id yepoda/pii-pepper/dev \
  --force-delete-without-recovery
```

Then re-run `terraform apply`.

---

## Project Structure

```
Order-data-Processing-Pipeline/
├── terraform/                  # Infrastructure as Code
│   ├── main.tf                 # Root module — composes all sub-modules in dependency order
│   ├── variables.tf            # Input variables (region, project name, retention, etc.)
│   ├── outputs.tf              # Prints endpoint URL, bucket names, query commands after apply
│   ├── providers.tf            # AWS provider (>= 5.0), random, archive; Terraform >= 1.6
│   ├── backend.tf              # Remote state config (S3 bucket supplied at init time)
│   ├── terraform.tfvars.example
│   └── modules/
│       ├── kms/                # 5 KMS CMKs: raw-data, processed-data, secrets, cloudtrail, cloudwatch-logs
│       ├── iam/                # Lambda + Glue IAM roles with least-privilege policies
│       ├── storage/            # S3 buckets (raw, processed, athena-results, cloudtrail) with lifecycle + encryption
│       ├── secrets/            # Secrets Manager — HMAC pepper for PII pseudonymization
│       ├── analytics/          # Glue database + table, Athena workgroup
│       ├── lambda/             # Lambda function (Python 3.12) + CloudWatch log group + alarms
│       ├── api_gateway/        # REST API Gateway with prod stage, throttling, CloudWatch logging
│       ├── monitoring/         # CloudTrail audit trail + CloudWatch dashboard + metric filters
│       └── vpc/                # VPC + private subnets + VPC endpoints (defined but not active
│                               # in current deployment — Lambda runs without VPC)
├── function/
│   ├── handler.py              # Lambda handler — validates, pseudonymizes PII, writes to S3
│   ├── requirements.txt
│   └── tests/
│       └── test_handler.py
├── scripts/
│   └── gdpr_erasure.py         # GDPR Article 17 right-to-erasure script
├── docs/
│   ├── architecture.md         # Architecture diagram + data flow
│   ├── aws_services.md         # Services justification
│   └── cost_estimation.md      # Monthly cost breakdown
├── README.md                   # This file
└── GDPR_COMPLIANCE.md          # GDPR compliance approach
```

> **Note on `function.zip`:** Terraform auto-generates this from the `function/` directory using
> the `archive_file` data source. No manual zip step is needed.
