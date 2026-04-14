###############################################################################
# modules/oci-compute/main.tf
# Ampere A1 (4 OCPU / 24 GB RAM) in private subnet
# cloud-init: Docker · Caddy · WireGuard · n8n · Motibot · Ghost
###############################################################################

data "oci_identity_availability_domains" "ads" {
  compartment_id = var.compartment_id

}

# Latest OCI Ubuntu 22.04 ARM image
data "oci_core_images" "ubuntu_arm" {
  compartment_id           = var.compartment_id
  operating_system         = "Canonical Ubuntu"
  operating_system_version = "22.04"
  shape                    = "VM.Standard.A1.Flex"
  sort_by                  = "TIMECREATED"
  sort_order               = "DESC"
}

resource "oci_core_instance" "ampere_a1" {
  availability_domain = var.availability_domain
  compartment_id      = var.compartment_id
  display_name        = "ampere-a1-apps"
  shape               = "VM.Standard.A1.Flex"

  shape_config {
    ocpus         = 4
    memory_in_gbs = 24
  }

  create_vnic_details {
    subnet_id        = var.private_subnet_id
    assign_public_ip = false # Private subnet — no public IP
    nsg_ids          = [var.compute_nsg_id]
    display_name     = "primary-vnic"
    hostname_label   = "ampere-a1"
  }

  source_details {
    source_type             = "image"
    source_id               = data.oci_core_images.ubuntu_arm.images[0].id
    boot_volume_size_in_gbs = 50 # Always-free: up to 200 GB total
  }

  metadata = {
    ssh_authorized_keys = var.ssh_public_key
    user_data           = base64encode(local.cloud_init)
  }

  # Prevent accidental destroy of the always-free compute
  lifecycle {
    prevent_destroy = true
    ignore_changes  = [source_details[0].source_id] # Don't replace on image update
  }

  freeform_tags = var.tags
}

locals {
  cloud_init = templatefile("${path.module}/cloud-init.yaml.tpl", {
    domain_name        = var.domain_name
    n8n_subdomain      = var.n8n_subdomain
    wg_subdomain       = var.wg_subdomain
    azure_tenant_id    = var.azure_tenant_id
    n8n_oidc_client_id = var.n8n_oidc_client_id
    n8n_oidc_secret    = var.n8n_oidc_secret
    tailscale_auth_key = var.tailscale_auth_key
    wireguard_host_ip  = var.wireguard_host_ip
  })
}
