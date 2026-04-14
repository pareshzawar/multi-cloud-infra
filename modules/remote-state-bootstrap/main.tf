###############################################################################
# modules/remote-state-bootstrap/main.tf
#
# Creates OCI Object Storage bucket for Terraform remote state.
# Run this ONCE before using the S3-compatible backend.
#
# Why OCI Object Storage for remote state?
#   - Always Free: 10 GB standard storage
#   - S3-compatible API (works with Terraform S3 backend)
#   - All 3 cloud providers need state — use a single free store
#   - Enables multi-device workflow: any laptop/device can run terraform
#
# SETUP ORDER:
#   1. Run this module standalone first (local state is fine for bootstrap)
#   2. Get the namespace: oci os ns get
#   3. Uncomment the backend block in environments/prod/main.tf
#   4. Run: terraform init -migrate-state
#   5. Delete local terraform.tfstate
###############################################################################

resource "oci_objectstorage_bucket" "tfstate" {
  compartment_id = var.compartment_id
  namespace      = var.namespace
  name           = var.bucket_name
  access_type    = "NoPublicAccess" # Private — never public

  versioning = "Enabled" # Keep history of state files — rollback safety

  freeform_tags = {
    purpose    = "terraform-remote-state"
    managed_by = "terraform-bootstrap"
  }
}

data "oci_objectstorage_namespace" "ns" {
  compartment_id = var.compartment_id
}

# S3-compatible credentials for Terraform backend
resource "oci_identity_customer_secret_key" "tfstate" {
  user_id      = var.user_ocid
  display_name = "terraform-state-key"
}
