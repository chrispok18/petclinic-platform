#!/usr/bin/env bash
set -euo pipefail

#
# bootstrap-state.sh — Create the Terraform remote state backend (PETPLAT-2)
#
# Creates (or brings into compliance) the shared state resources:
#   - S3 bucket  petclinic-terraform-state-{account-id}
#       versioning, SSE-S3 (AES256), all 4 public access blocks
#   - DynamoDB   petclinic-terraform-locks (LockID string partition key)
#
# Idempotent: existing resources are reused and their settings re-applied.
# The account ID is never printed.
#
# Usage:
#   ./scripts/bootstrap-state.sh
#   ./scripts/bootstrap-state.sh --region eu-central-1
#

REGION="eu-central-1"
TABLE_NAME="petclinic-terraform-locks"
TAGS_KV="Key=Project,Value=petclinic Key=Environment,Value=shared Key=ManagedBy,Value=bootstrap-script"

usage() {
  echo "Usage: $0 [--region <aws-region>]"
  echo "  --region   AWS region for the state bucket and lock table (default: eu-central-1)"
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --region)
      [[ $# -ge 2 && -n "$2" ]] || usage
      REGION="$2"
      shift 2
      ;;
    --region=*)
      REGION="${1#*=}"
      [[ -n "${REGION}" ]] || usage
      shift
      ;;
    -h|--help)
      usage
      ;;
    *)
      echo "Error: unknown argument '$1'"
      usage
      ;;
  esac
done

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
BUCKET_NAME="petclinic-terraform-state-${ACCOUNT_ID}"
BUCKET_DISPLAY="petclinic-terraform-state-<ACCOUNT_ID>"

echo "============================================"
echo "  Bootstrapping Terraform state backend"
echo "  Region: ${REGION}"
echo "============================================"
echo ""

# --- S3 Bucket ---
echo "[1/2] S3 bucket: ${BUCKET_DISPLAY}"

if aws s3api head-bucket --bucket "${BUCKET_NAME}" --expected-bucket-owner "${ACCOUNT_ID}" 2>/dev/null; then
  echo "  -> Bucket already exists in this account. Re-applying settings."
else
  echo "  -> Creating bucket..."
  # us-east-1 rejects an explicit LocationConstraint
  if [[ "${REGION}" == "us-east-1" ]]; then
    aws s3api create-bucket --bucket "${BUCKET_NAME}" --region "${REGION}" > /dev/null
  else
    aws s3api create-bucket --bucket "${BUCKET_NAME}" --region "${REGION}" \
      --create-bucket-configuration "LocationConstraint=${REGION}" > /dev/null
  fi
  aws s3api wait bucket-exists --bucket "${BUCKET_NAME}" --region "${REGION}"
fi

aws s3api put-public-access-block --bucket "${BUCKET_NAME}" --region "${REGION}" \
  --public-access-block-configuration \
  "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"
echo "  -> Public access blocked (all 4 settings)."

aws s3api put-bucket-versioning --bucket "${BUCKET_NAME}" --region "${REGION}" \
  --versioning-configuration Status=Enabled
echo "  -> Versioning enabled."

aws s3api put-bucket-encryption --bucket "${BUCKET_NAME}" --region "${REGION}" \
  --server-side-encryption-configuration \
  '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'
echo "  -> Default encryption: AES256 (SSE-S3)."

aws s3api put-bucket-tagging --bucket "${BUCKET_NAME}" --region "${REGION}" \
  --tagging "TagSet=[{Key=Project,Value=petclinic},{Key=Environment,Value=shared},{Key=ManagedBy,Value=bootstrap-script}]"
echo "  -> Tags applied."
echo ""

# --- DynamoDB Lock Table ---
echo "[2/2] DynamoDB table: ${TABLE_NAME}"

if aws dynamodb describe-table --table-name "${TABLE_NAME}" --region "${REGION}" > /dev/null 2>&1; then
  echo "  -> Table already exists. Skipping creation."
else
  echo "  -> Creating table..."
  # shellcheck disable=SC2086
  aws dynamodb create-table \
    --table-name "${TABLE_NAME}" \
    --attribute-definitions AttributeName=LockID,AttributeType=S \
    --key-schema AttributeName=LockID,KeyType=HASH \
    --billing-mode PAY_PER_REQUEST \
    --sse-specification Enabled=true \
    --tags ${TAGS_KV} \
    --region "${REGION}" > /dev/null
  aws dynamodb wait table-exists --table-name "${TABLE_NAME}" --region "${REGION}"
  echo "  -> Table is active."
fi

echo ""
echo "============================================"
echo "  State backend ready."
echo "  Next: cd terraform/environments/dev && terraform init"
echo "============================================"
