# Declares which provider this module uses. Without this block Terraform
# assumes the "hashicorp/oci" namespace, which is not Oracle's provider.
terraform {
  required_providers {
    oci = {
      source = "oracle/oci"
    }
  }
}
