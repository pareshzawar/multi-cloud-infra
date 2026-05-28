###############################################################################
# environments/prod/backend.tf
#
# CHANGES:
#   FIXED  "endpoint" deprecated param → "endpoints" block with "s3" key
#   FIXED  SignatureDoesNotMatch: OCI S3-compat backend needs explicit
#          access_key / secret_key passed — cannot rely on AWS env vars
#          (those are your real AWS creds, wrong signer for OCI endpoint)
#   ADDED  skip_region_validation = true — OCI region isn't an AWS region
#   ADDED  use_path_style = true (replaces deprecated force_path_style)
###############################################################################

terraform {
  required_version = ">= 1.7.5"

  backend "s3" {
    bucket = "terraform-state-multicloud"
    key    = "prod/terraform.tfstate"
    region = "us-ashburn-1"

    # FIXED: replaces deprecated "endpoint" parameter
    endpoints = {
      s3 = "https://idkl5fdwo72e.compat.objectstorage.us-ashburn-1.oraclecloud.com"
    }

    # OCI Object Storage S3-compat requires its own key pair — NOT your AWS
    # access keys. These are OCI Customer Secret Keys (generated in OCI Console
    # → Profile → Customer Secret Keys). Passed at init time via -backend-config
    # or as env vars: AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY scoped to OCI.
    # See terraform.yml — the init step sets these from OCI-specific secrets.
    # (leaving unset here so the file is safe to commit)

    skip_credentials_validation = true
    skip_metadata_api_check     = true
    skip_region_validation      = true   # ADDED: us-ashburn-1 isn't an AWS region
    use_path_style              = true   # REPLACES deprecated force_path_style
  }
}
