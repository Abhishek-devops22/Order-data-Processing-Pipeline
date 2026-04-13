# Remote state in S3.
# Create this bucket BEFORE running terraform init:
#
#   aws s3api create-bucket \
#     --bucket your-project-tfstate \
#     --region eu-central-1 \
#     --create-bucket-configuration LocationConstraint=eu-central-1
#
#   aws s3api put-bucket-versioning \
#     --bucket your-project-tfstate \
#     --versioning-configuration Status=Enabled
#
#   aws s3api put-bucket-encryption \
#     --bucket your-project-tfstate \
#     --server-side-encryption-configuration \
#       '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'
#
# Then initialise:
#   terraform init \
#     -backend-config="bucket=your-project-tfstate" \
#     -backend-config="key=order-pipeline/terraform.tfstate" \
#     -backend-config="region=eu-central-1"

terraform {
  backend "s3" {
    # Supplied via -backend-config at init time (see above)
    encrypt = true
  }
}
