###############################################################################
# modules/oci-networking/main.tf
# VCN · Public Subnet (LB) · Private Subnet (Compute)
# Internet Gateway · NAT Gateway · Service Gateway
###############################################################################

# ── VCN ──────────────────────────────────────────────────────────────────────

resource "oci_core_vcn" "main" {
  compartment_id = var.compartment_id
  cidr_blocks    = [var.vcn_cidr]
  display_name   = "multi-cloud-vcn"
  dns_label      = "multicloud"

  freeform_tags = var.tags
}

# ── Gateways ──────────────────────────────────────────────────────────────────

resource "oci_core_internet_gateway" "igw" {
  compartment_id = var.compartment_id
  vcn_id         = oci_core_vcn.main.id
  enabled        = true
  display_name   = "internet-gateway"

  freeform_tags = var.tags
}

resource "oci_core_nat_gateway" "nat" {
  compartment_id = var.compartment_id
  vcn_id         = oci_core_vcn.main.id
  display_name   = "nat-gateway"
  # block_traffic  = false  # Enable to block all outbound NAT (security lockdown)

  freeform_tags = var.tags
}

# Service Gateway — allows private subnet to reach OCI services (Object Storage etc.)
# without going through NAT/Internet
data "oci_core_services" "all" {}

resource "oci_core_service_gateway" "svcgw" {
  compartment_id = var.compartment_id
  vcn_id         = oci_core_vcn.main.id
  display_name   = "service-gateway"

  services {
    service_id = data.oci_core_services.all.services[0].id
  }

  freeform_tags = var.tags
}

# ── Route Tables ──────────────────────────────────────────────────────────────

# Public subnet route table — default route to Internet Gateway
resource "oci_core_route_table" "public" {
  compartment_id = var.compartment_id
  vcn_id         = oci_core_vcn.main.id
  display_name   = "public-route-table"

  route_rules {
    destination       = "0.0.0.0/0"
    destination_type  = "CIDR_BLOCK"
    network_entity_id = oci_core_internet_gateway.igw.id
  }

  freeform_tags = var.tags
}

# Private subnet route table — default route through NAT Gateway
resource "oci_core_route_table" "private" {
  compartment_id = var.compartment_id
  vcn_id         = oci_core_vcn.main.id
  display_name   = "private-route-table"

  # Default route to NAT for internet access (updates, Docker pulls)
  route_rules {
    destination       = "0.0.0.0/0"
    destination_type  = "CIDR_BLOCK"
    network_entity_id = oci_core_nat_gateway.nat.id
  }

  # OCI services (Object Storage) via Service Gateway — no NAT needed
  route_rules {
    destination       = data.oci_core_services.all.services[0].cidr_block
    destination_type  = "SERVICE_CIDR_BLOCK"
    network_entity_id = oci_core_service_gateway.svcgw.id
  }

  freeform_tags = var.tags
}

# ── Subnets ───────────────────────────────────────────────────────────────────

# Public subnet — only the Load Balancer lives here
resource "oci_core_subnet" "public" {
  compartment_id             = var.compartment_id
  vcn_id                     = oci_core_vcn.main.id
  cidr_block                 = var.public_subnet_cidr
  display_name               = "public-lb-subnet"
  dns_label                  = "lbsubnet"
  prohibit_public_ip_on_vnic = false # LB needs a public IP
  route_table_id             = oci_core_route_table.public.id

  freeform_tags = var.tags
}

# Private subnet — Ampere A1 compute only
resource "oci_core_subnet" "private" {
  compartment_id             = var.compartment_id
  vcn_id                     = oci_core_vcn.main.id
  cidr_block                 = var.private_subnet_cidr
  display_name               = "private-compute-subnet"
  dns_label                  = "computesubnet"
  prohibit_public_ip_on_vnic = true # No public IP — all traffic via LB
  route_table_id             = oci_core_route_table.private.id

  freeform_tags = var.tags
}
