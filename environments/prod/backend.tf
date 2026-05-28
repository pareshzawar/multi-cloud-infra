###############################################################################
# environments/prod/backend.tf
###############################################################################

terraform {
  required_version = ">= 1.7.5"

  backend "s3" {
    bucket = "terraform-state-multicloud"
    key    = "prod/terraform.tfstate"
    region = "us-ashburn-1"

    endpoints = {
      s3 = "https://idkl5fdwo72e.compat.objectstorage.us-ashburn-1.oraclecloud.com"
    }

    skip_credentials_validation  = true
    skip_metadata_api_check      = true
    skip_region_validation       = true
    use_path_style               = true

    # Prevents the S3 backend from calling STS to look up the AWS account ID.
    # Without this, the backend uses its own region (us-ashburn-1) to construct
    # an STS endpoint (sts.us-ashburn-1.amazonaws.com) which doesn't exist.
    skip_requesting_account_id   = true
  }
}
