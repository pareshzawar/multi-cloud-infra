###############################################################################
# modules/oci-lb/main.tf
# Always-Free Flexible Load Balancer (10 Mbps)
# HTTP listener → HTTPS redirect
# HTTPS listener → backend Ampere A1 (Caddy)
# WireGuard UDP passthrough
###############################################################################

resource "oci_load_balancer_load_balancer" "main" {
  compartment_id = var.compartment_id
  display_name   = "flexible-lb-main"
  shape          = "flexible"
  subnet_ids     = [var.public_subnet_id]

  # Always-Free = 10 Mbps min/max
  shape_details {
    minimum_bandwidth_in_mbps = 10
    maximum_bandwidth_in_mbps = 10
  }

  network_security_group_ids = [var.lb_nsg_id]
  is_private                 = false # Public-facing

  freeform_tags = var.tags
}

# ── Backend Set: HTTPS (Caddy on Ampere A1) ───────────────────────────────────

resource "oci_load_balancer_backend_set" "https" {
  load_balancer_id = oci_load_balancer_load_balancer.main.id
  name             = "bs-https"
  policy           = "ROUND_ROBIN"

  health_checker {
    protocol          = "HTTP"
    port              = 80
    url_path          = "/health"
    interval_ms       = 30000
    timeout_in_millis = 3000
    retries           = 3
    return_code       = 200
  }
}

resource "oci_load_balancer_backend" "https_backend" {
  load_balancer_id = oci_load_balancer_load_balancer.main.id
  backendset_name  = oci_load_balancer_backend_set.https.name
  ip_address       = var.backend_instance_ip
  port             = 443
  weight           = 1
  backup           = false
  drain            = false
  offline          = false
}

# ── Backend Set: HTTP (for redirect to HTTPS) ─────────────────────────────────

resource "oci_load_balancer_backend_set" "http_redirect" {
  load_balancer_id = oci_load_balancer_load_balancer.main.id
  name             = "bs-http-redirect"
  policy           = "ROUND_ROBIN"

  health_checker {
    protocol          = "HTTP"
    port              = 80
    url_path          = "/health"
    interval_ms       = 30000
    timeout_in_millis = 3000
    retries           = 3
    return_code       = 301
  }
}

# ── Listener: HTTP (port 80) → redirect to HTTPS ──────────────────────────────

resource "oci_load_balancer_listener" "http" {
  load_balancer_id         = oci_load_balancer_load_balancer.main.id
  name                     = "listener-http"
  default_backend_set_name = oci_load_balancer_backend_set.http_redirect.name
  port                     = 80
  protocol                 = "HTTP"

  rule_set_names = [oci_load_balancer_rule_set.https_redirect.name]
}

# Rule set: permanent redirect HTTP → HTTPS
resource "oci_load_balancer_rule_set" "https_redirect" {
  load_balancer_id = oci_load_balancer_load_balancer.main.id
  name             = "https_redirect"

  items {
    action = "REDIRECT"

    conditions {
      attribute_name  = "PATH"
      attribute_value = "/"
      operator        = "FORCE_LONGEST_PREFIX_MATCH"
    }

    redirect_uri {
      protocol = "HTTPS"
      host     = "{host}"
      port     = 443
      path     = "/{path}"
      query    = "?{query}"
    }

    response_code = 301
  }
}

# ── Listener: HTTPS (port 443) ────────────────────────────────────────────────
# SSL is terminated by Caddy on the backend — LB passes through TCP

resource "oci_load_balancer_listener" "https" {
  load_balancer_id         = oci_load_balancer_load_balancer.main.id
  name                     = "listener-https"
  default_backend_set_name = oci_load_balancer_backend_set.https.name
  port                     = 443
  protocol                 = "TCP" # TCP passthrough — Caddy handles TLS
}

# ── Network Load Balancer: WireGuard UDP ──────────────────────────────────────
# Use the Always-Free Network Load Balancer for UDP passthrough

resource "oci_network_load_balancer_network_load_balancer" "wireguard" {
  compartment_id                 = var.compartment_id
  display_name                   = "nlb-wireguard"
  subnet_id                      = var.public_subnet_id
  is_private                     = false
  is_preserve_source_destination = false

  freeform_tags = var.tags
}

resource "oci_network_load_balancer_backend_set" "wg" {
  network_load_balancer_id = oci_network_load_balancer_network_load_balancer.wireguard.id
  name                     = "bs-wireguard"
  policy                   = "FIVE_TUPLE"
  is_preserve_source       = false

  health_checker {
    protocol = "UDP"
    port     = 51820
    # UDP requires hex data to send and expect back
    request_data  = "70696e67" # Hex for "ping"
    response_data = "706f6e67" # Hex for "pong" (or whatever WG replies with)
  }
}

resource "oci_network_load_balancer_backend" "wg_backend" {
  network_load_balancer_id = oci_network_load_balancer_network_load_balancer.wireguard.id
  backend_set_name         = oci_network_load_balancer_backend_set.wg.name
  name                     = "wg-backend"
  ip_address               = var.backend_instance_ip
  port                     = 51820
  is_backup                = false
  is_drain                 = false
  is_offline               = false
  weight                   = 1
}

resource "oci_network_load_balancer_listener" "wg" {
  network_load_balancer_id = oci_network_load_balancer_network_load_balancer.wireguard.id
  name                     = "listener-wireguard"
  default_backend_set_name = oci_network_load_balancer_backend_set.wg.name
  port                     = 51820
  protocol                 = "UDP"
}
