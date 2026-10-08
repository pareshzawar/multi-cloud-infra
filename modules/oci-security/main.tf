###############################################################################
# modules/oci-security/main.tf
# NSGs (Network Security Groups) + Security Lists
# Defense-in-Depth: deny-all default, explicit allow per service
###############################################################################

# ── NSG: Load Balancer ────────────────────────────────────────────────────────
# Only accepts HTTP/HTTPS from the internet (via Cloudflare IPs ideally)

resource "oci_core_network_security_group" "lb" {
  compartment_id = var.compartment_id
  vcn_id         = var.vcn_id
  display_name   = "nsg-load-balancer"
  freeform_tags  = var.tags
}

# HTTP inbound — Cloudflare will handle TLS, redirect to HTTPS
resource "oci_core_network_security_group_security_rule" "lb_http_in" {
  network_security_group_id = oci_core_network_security_group.lb.id
  direction                 = "INGRESS"
  protocol                  = "6" # TCP
  source                    = "0.0.0.0/0"
  source_type               = "CIDR_BLOCK"
  stateless                 = false

  tcp_options {
    destination_port_range {
      min = 80
      max = 80
    }
  }
}

# HTTPS inbound
resource "oci_core_network_security_group_security_rule" "lb_https_in" {
  network_security_group_id = oci_core_network_security_group.lb.id
  direction                 = "INGRESS"
  protocol                  = "6"
  source                    = "0.0.0.0/0"
  source_type               = "CIDR_BLOCK"
  stateless                 = false

  tcp_options {
    destination_port_range {
      min = 443
      max = 443
    }
  }
}

# All egress from LB allowed (to backend compute)
resource "oci_core_network_security_group_security_rule" "lb_egress_all" {
  network_security_group_id = oci_core_network_security_group.lb.id
  direction                 = "EGRESS"
  protocol                  = "all"
  destination               = "0.0.0.0/0"
  destination_type          = "CIDR_BLOCK"
  stateless                 = false
}

# ── NSG: Compute (Ampere A1) ──────────────────────────────────────────────────
# Only accepts traffic from the LB NSG — no direct internet access

resource "oci_core_network_security_group" "compute" {
  compartment_id = var.compartment_id
  vcn_id         = var.vcn_id
  display_name   = "nsg-compute-ampere"
  freeform_tags  = var.tags
}

# HTTP from LB only
resource "oci_core_network_security_group_security_rule" "compute_http_from_lb" {
  network_security_group_id = oci_core_network_security_group.compute.id
  direction                 = "INGRESS"
  protocol                  = "6"
  source                    = oci_core_network_security_group.lb.id
  source_type               = "NETWORK_SECURITY_GROUP"
  stateless                 = false

  tcp_options {
    destination_port_range {
      min = 80
      max = 80
    }
  }
}

# HTTPS from LB only
resource "oci_core_network_security_group_security_rule" "compute_https_from_lb" {
  network_security_group_id = oci_core_network_security_group.compute.id
  direction                 = "INGRESS"
  protocol                  = "6"
  source                    = oci_core_network_security_group.lb.id
  source_type               = "NETWORK_SECURITY_GROUP"
  stateless                 = false

  tcp_options {
    destination_port_range {
      min = 443
      max = 443
    }
  }
}

# WireGuard from the Network Load Balancer. The NLB is not a member of the LB
# NSG, so match on the public subnet CIDR where its private IP lives.
resource "oci_core_network_security_group_security_rule" "compute_wg_from_lb" {
  network_security_group_id = oci_core_network_security_group.compute.id
  direction                 = "INGRESS"
  protocol                  = "17"
  source                    = var.public_subnet_cidr
  source_type               = "CIDR_BLOCK"
  stateless                 = false

  udp_options {
    destination_port_range {
      min = 51820
      max = 51820
    }
  }
}

# SSH — admin only (from allowed CIDRs, e.g. your home IP via Bastion or Tailscale)
resource "oci_core_network_security_group_security_rule" "compute_ssh_admin" {
  for_each = toset(var.admin_allowed_cidrs)

  network_security_group_id = oci_core_network_security_group.compute.id
  direction                 = "INGRESS"
  protocol                  = "6"
  source                    = each.value
  source_type               = "CIDR_BLOCK"
  stateless                 = false

  tcp_options {
    destination_port_range {
      min = 22
      max = 22
    }
  }
}

# Tailscale UDP inbound (for mesh connectivity)
resource "oci_core_network_security_group_security_rule" "compute_tailscale_in" {
  network_security_group_id = oci_core_network_security_group.compute.id
  direction                 = "INGRESS"
  protocol                  = "17"
  source                    = "0.0.0.0/0"
  source_type               = "CIDR_BLOCK"
  stateless                 = true

  udp_options {
    destination_port_range {
      min = 41641
      max = 41641
    }
  }
}

# Portainer agent on A1 — only the ops node (micro2 NSG) may connect
resource "oci_core_network_security_group_security_rule" "compute_portainer_agent_from_micro2" {
  network_security_group_id = oci_core_network_security_group.compute.id
  direction                 = "INGRESS"
  protocol                  = "6"
  source                    = oci_core_network_security_group.micro2.id
  source_type               = "NETWORK_SECURITY_GROUP"
  stateless                 = false

  tcp_options {
    destination_port_range {
      min = 9001
      max = 9001
    }
  }
}

# All egress from compute (internet access via NAT GW)
resource "oci_core_network_security_group_security_rule" "compute_egress_all" {
  network_security_group_id = oci_core_network_security_group.compute.id
  direction                 = "EGRESS"
  protocol                  = "all"
  destination               = "0.0.0.0/0"
  destination_type          = "CIDR_BLOCK"
  stateless                 = false
}

# ── NSG: Micro #2 (Ops node) ─────────────────────────────────────────────────
# Uptime Kuma + Portainer + Watchtower
# Admin UIs bound to localhost and published to the tailnet with
# `tailscale serve` (HTTPS) — no inbound VCN/internet port is needed for them.

resource "oci_core_network_security_group" "micro2" {
  compartment_id = var.compartment_id
  vcn_id         = var.vcn_id
  display_name   = "nsg-micro2-ops"
  freeform_tags  = var.tags
}

# Tailscale UDP — mesh formation
resource "oci_core_network_security_group_security_rule" "micro2_tailscale_in" {
  network_security_group_id = oci_core_network_security_group.micro2.id
  direction                 = "INGRESS"
  protocol                  = "17"
  source                    = "0.0.0.0/0"
  source_type               = "CIDR_BLOCK"
  stateless                 = true

  udp_options {
    destination_port_range {
      min = 41641
      max = 41641
    }
  }
}

# SSH — admin CIDRs only (same policy as compute NSG)
resource "oci_core_network_security_group_security_rule" "micro2_ssh" {
  for_each = toset(var.admin_allowed_cidrs)

  network_security_group_id = oci_core_network_security_group.micro2.id
  direction                 = "INGRESS"
  protocol                  = "6"
  source                    = each.value
  source_type               = "CIDR_BLOCK"
  stateless                 = false

  tcp_options {
    destination_port_range {
      min = 22
      max = 22
    }
  }
}

# All egress (outbound for Docker pulls, Tailscale, apt updates)
resource "oci_core_network_security_group_security_rule" "micro2_egress" {
  network_security_group_id = oci_core_network_security_group.micro2.id
  direction                 = "EGRESS"
  protocol                  = "all"
  destination               = "0.0.0.0/0"
  destination_type          = "CIDR_BLOCK"
  stateless                 = false
}
