# Cost Estimation — eu-central-1 (Frankfurt)

Based on **10,000 orders/month** in dev environment. Prices as of 2024.

## Monthly Cost Breakdown

| Service | Usage Assumption | Est. Monthly Cost (USD) |
|---------|-----------------|------------------------|
| **AWS Lambda** | 10,000 invocations × 256MB × 2s avg | ~$0.01 |
| **API Gateway** | 10,000 REST API calls | ~$0.04 |
| **S3 (raw-orders)** | 10,000 objects × ~2KB = ~20MB storage | ~$0.01 |
| **S3 (processed-orders)** | 10,000 objects × ~1KB = ~10MB storage | ~$0.01 |
| **S3 (CloudTrail logs)** | ~50MB audit logs | ~$0.01 |
| **AWS KMS** | 4 CMKs × $1/month + ~40,000 API calls | ~$4.08 |
| **Secrets Manager** | 1 secret + ~10,000 API calls | ~$0.44 |
| **AWS Glue** | Catalog only (no crawler/ETL jobs) | $0.00 |
| **Amazon Athena** | 10 analyst queries × 10MB scanned | ~$0.00 |
| **CloudTrail** | Management events free, data events charged | ~$0.10 |
| **CloudWatch** | Logs ingestion ~50MB, 3 alarms, 1 dashboard | ~$0.55 |
| **SNS** | <1,000 notifications | ~$0.00 |
| **Total (dev)** | | **~$5.25/month** |

## Production Scale Estimate (1M orders/month)

| Service | Cost |
|---------|------|
| Lambda | ~$1.00 |
| API Gateway | ~$3.50 |
| S3 (all buckets) | ~$5.00 |
| KMS | ~$6.00 |
| Secrets Manager | ~$1.40 |
| Athena | ~$5.00 |
| CloudTrail | ~$10.00 |
| CloudWatch | ~$15.00 |
| **Total (prod)** | **~$47/month** |

## Cost Optimisation Notes

- **S3 Intelligent-Tiering** not used — lifecycle rules handle tiering deterministically (Standard → IA after 90d → Glacier after 365d)
- **Lambda power tuning**: 256MB is sufficient; increasing to 512MB might reduce duration cost at scale
- **KMS bucket keys enabled**: reduces KMS API calls by ~99% on S3 operations (major cost saver)
- **Athena**: partitioned table (`year/month/day`) ensures analysts scan only the data they need
- **No NAT Gateway**: Lambda not in VPC avoids ~$45/month NAT gateway cost in dev; add for production via `enable_vpc = true` variable
