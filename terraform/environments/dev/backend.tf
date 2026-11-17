# Remote state (technical-spec: Terraform State Backend).
# Bucket and table are created by scripts/bootstrap-state.sh (PETPLAT-2).
#
# Replace <ACCOUNT_ID> with your AWS account ID before `terraform init`,
# or leave the placeholder and pass the real name at init time:
#   terraform init -backend-config="bucket=petclinic-terraform-state-$(aws sts get-caller-identity --query Account --output text)"
terraform {
  backend "s3" {
    bucket         = "petclinic-terraform-state-<ACCOUNT_ID>"
    key            = "petclinic/dev/terraform.tfstate"
    region         = "eu-central-1"
    dynamodb_table = "petclinic-terraform-locks"
    encrypt        = true
  }
}
