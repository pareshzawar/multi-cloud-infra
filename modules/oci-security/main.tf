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

# WireGuard UDP — inbound to LB (LB passes UDP to backend)
resource "oci_core_network_security_group_security_rule" "lb_wireguard_in" {
  network_security_group_id = oci_core_network_security_group.lb.id
  direction                 = "INGRESS"
  protocol                  = "17" # UDP
  source                    = "0.0.0.0/0"
  source_type               = "CIDR_BLOCK"
  stateless                 = true # UDP is stateless

  udp_options {
    destination_port_range {
      min = 51820
      max = 51820
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

# WireGuard from LB
resource "oci_core_network_security_group_security_rule" "compute_wg_from_lb" {
  network_security_group_id = oci_core_network_security_group.compute.id
  direction                 = "INGRESS"
  protocol                  = "17"
  source                    = oci_core_network_security_group.lb.id
  source_type               = "NETWORK_SECURITY_GROUP"
  stateless                 = true

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

# All egress from compute (internet access via NAT GW)
resource "oci_core_network_security_group_security_rule" "compute_egress_all" {
  network_security_group_id = oci_core_network_security_group.compute.id
  direction                 = "EGRESS"
  protocol                  = "all"
  destination               = "0.0.0.0/0"
  destination_type          = "CIDR_BLOCK"
  stateless                 = false
}

# ── Security List: Public Subnet ──────────────────────────────────────────────

resource "oci_core_security_list" "public" {
  compartment_id = var.compartment_id
  vcn_id         = var.vcn_id
  display_name   = "sl-public-subnet"
  freeform_tags  = var.tags

  ingress_security_rules {
    protocol  = "6"
    source    = "0.0.0.0/0"
    stateless = false
    tcp_options {
      min = 80
      max = 80
    }
  }

  ingress_security_rules {
    protocol  = "6"
    source    = "0.0.0.0/0"
    stateless = false
    tcp_options {
      min = 443
      max = 443
    }
  }

  ingress_security_rules {
    protocol  = "17"
    source    = "0.0.0.0/0"
    stateless = true
    udp_options {
      min = 51820
      max = 51820
    }
  }

  # ICMP — allow ping for troubleshooting
  ingress_security_rules {
    protocol  = "1"
    source    = "0.0.0.0/0"
    stateless = false
    icmp_options {
      type = 3
      code = 4
    }
  }

  egress_security_rules {
    protocol    = "all"
    destination = "0.0.0.0/0"
    stateless   = false
  }
}

# ── Security List: Private Subnet ─────────────────────────────────────────────

resource "oci_core_security_list" "private" {
  compartment_id = var.compartment_id
  vcn_id         = var.vcn_id
  display_name   = "sl-private-subnet"
  freeform_tags  = var.tags

  # Accept traffic from public subnet (LB → compute)
  ingress_security_rules {
    protocol  = "6"
    source    = var.public_subnet_cidr
    stateless = false
    tcp_options {
      min = 1
      max = 65535
    }
  }

  ingress_security_rules {
    protocol  = "17"
    source    = "0.0.0.0/0"
    stateless = true
    udp_options {
      min = 41641
      max = 41641
    }
  }

  ingress_security_rules {
    protocol  = "17"
    source    = "0.0.0.0/0"
    stateless = true
    udp_options {
      min = 51820
      max = 51820
    }
  }

  # ICMP within VCN
  ingress_security_rules {
    protocol  = "1"
    source    = "10.0.0.0/16"
    stateless = false
    icmp_options {
      type = 3
      code = 4
    }
  }

  egress_security_rules {
    protocol    = "all"
    destination = "0.0.0.0/0"
    stateless   = false
  }
}

# ── NSG: Micro #2 (Ops node) ─────────────────────────────────────────────────
# Uptime Kuma + Portainer + Watchtower
# Admin UIs bound to localhost — only Tailscale tunnel reaches them
# Portainer agent port (9001) open to OCI VCN range so A1 can connect

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

# Portainer agent — reachable from OCI VCN private range (A1 → micro2 direct)
resource "oci_core_network_security_group_security_rule" "micro2_portainer_agent" {
  network_security_group_id = oci_core_network_security_group.micro2.id
  direction                 = "INGRESS"
  protocol                  = "6"
  source                    = "10.0.0.0/16" # OCI VCN — A1 is in 10.0.2.0/24
  source_type               = "CIDR_BLOCK"
  stateless                 = false

  tcp_options {
    destination_port_range {
      min = 9001
      max = 9001
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
