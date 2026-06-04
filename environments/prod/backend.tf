###############################################################################
# environments/prod/backend.tf
#
# The S3 backend and AWS provider share AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY
# env vars but need completely different credentials:
#   backend  → OCI Customer Secret Keys  (for OCI Object Storage)
#   provider → Real AWS keys             (for EC2, S3, etc.)
#
# Solution: hardcode OCI credentials directly in the backend block using
# access_key / secret_key attributes. Backend reads these first and never
# falls back to env vars. Env vars then carry real AWS creds for the provider.
#
# access_key and secret_key are passed via -backend-config at init time:
#   terraform init \
#     -backend-config="access_key=$OCI_STATE_ACCESS_KEY" \
#     -backend-config="secret_key=$OCI_STATE_SECRET_KEY"
#
# These are injected by GitHub Actions — see terraform.yml init step.
# The attributes are intentionally absent here so the file is safe to commit.
###############################################################################

terraform {
  required_version = ">= 1.7.5"

  backend "s3" {
    bucket = "terraform-state-multicloud"
    key    = "prod/terraform.tfstate"
    region = "ap-hyderabad-1"

    endpoints = {
      s3 = "https://axhnniwa9lf0.compat.objectstorage.ap-hyderabad-1.oraclecloud.com"
    }

    skip_credentials_validation = true
    skip_metadata_api_check     = true
    skip_region_validation      = true
    skip_requesting_account_id  = true
    use_path_style              = true
  }
}
