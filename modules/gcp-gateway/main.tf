###############################################################################
# modules/gcp-gateway/main.tf
# GCP e2-micro — Always Free (us-central1 / us-east1 / us-west1 ONLY)
# Sole role: Public Gateway — Nginx Proxy Manager routes traffic → OCI via Tailscale
# Uptime Kuma moved to OCI Micro #2 (same VCN as A1, lower hop latency)
###############################################################################

data "google_compute_image" "ubuntu_22" {
  family  = "ubuntu-2204-lts"
  project = "ubuntu-os-cloud"
}

# ── VPC ───────────────────────────────────────────────────────────────────────

resource "google_compute_network" "gateway" {
  name                    = "gateway-vpc"
  auto_create_subnetworks = false
  project                 = var.project_id
}

resource "google_compute_subnetwork" "gateway" {
  name          = "gateway-subnet"
  ip_cidr_range = var.vpc_cidr
  region        = var.region
  network       = google_compute_network.gateway.id
  project       = var.project_id

  # Enable flow logs for security auditing (free tier: 5 GB/mo logs)
  log_config {
    aggregation_interval = "INTERVAL_5_MIN"
    flow_sampling        = 0.5
    metadata             = "INCLUDE_ALL_METADATA"
  }
}

# ── Firewall Rules ────────────────────────────────────────────────────────────

# Allow HTTP/HTTPS from internet (Cloudflare → GCP)
resource "google_compute_firewall" "allow_http_https" {
  name    = "gateway-allow-http-https"
  network = google_compute_network.gateway.name
  project = var.project_id

  allow {
    protocol = "tcp"
    ports    = ["80", "443"]
  }

  source_ranges = ["0.0.0.0/0"]
  target_tags   = ["gateway"]
  description   = "Allow HTTP/HTTPS from internet"
}

# Allow Tailscale UDP
resource "google_compute_firewall" "allow_tailscale" {
  name    = "gateway-allow-tailscale"
  network = google_compute_network.gateway.name
  project = var.project_id

  allow {
    protocol = "udp"
    ports    = ["41641"]
  }

  source_ranges = ["0.0.0.0/0"]
  target_tags   = ["gateway"]
  description   = "Allow Tailscale mesh VPN"
}

# Allow SSH — restricted to Google's IAP range for secure access
resource "google_compute_firewall" "allow_ssh_iap" {
  name    = "gateway-allow-ssh-iap"
  network = google_compute_network.gateway.name
  project = var.project_id

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }

  # Google IAP tunnel source range — allows SSH via `gcloud compute ssh`
  source_ranges = ["35.235.240.0/20"]
  target_tags   = ["gateway"]
  description   = "SSH via Google IAP only"
}

# Allow Nginx Proxy Manager admin UI — from Tailscale range only
resource "google_compute_firewall" "allow_npm_admin" {
  name    = "gateway-allow-npm-admin"
  network = google_compute_network.gateway.name
  project = var.project_id

  allow {
    protocol = "tcp"
    ports    = ["81"] # Nginx Proxy Manager UI
  }

  # Tailscale CGNAT range — only accessible via VPN
  source_ranges = ["100.64.0.0/10"]
  target_tags   = ["gateway"]
  description   = "NPM admin — Tailscale only"
}

# Note: Uptime Kuma firewall rule removed — service moved to OCI Micro #2

# ── Static IP ─────────────────────────────────────────────────────────────────

resource "google_compute_address" "gateway" {
  name    = "gateway-static-ip"
  region  = var.region
  project = var.project_id
}

# ── Compute Engine: e2-micro ──────────────────────────────────────────────────

resource "google_compute_instance" "gateway" {
  name         = "gateway-e2-micro"
  machine_type = "e2-micro"
  zone         = var.zone
  project      = var.project_id

  tags = ["gateway"]

  boot_disk {
    initialize_params {
      image = data.google_compute_image.ubuntu_22.self_link
      size  = 30 # GB — Always Free includes 30 GB standard persistent disk
      type  = "pd-standard"
    }
  }

  network_interface {
    subnetwork = google_compute_subnetwork.gateway.id

    access_config {
      nat_ip = google_compute_address.gateway.address
    }
  }

  metadata = {
    ssh-keys  = "ubuntu:${var.ssh_public_key}"
    user-data = local.gateway_cloud_init
  }

  service_account {
    scopes = ["cloud-platform"]
  }

  lifecycle {
    prevent_destroy = true
    ignore_changes = [metadata["user-data"], boot_disk[0].initialize_params[0].image]
  }
}

locals {
  gateway_cloud_init = <<-EOF
    #!/bin/bash
    set -euo pipefail

    # ── System update ──────────────────────────────────────────────────────
    apt-get update && apt-get upgrade -y
    apt-get install -y curl wget git ufw fail2ban

    # ── Swapfile ──────────────────────────────────────────────────────────
    fallocate -l 2G /swapfile
    chmod 600 /swapfile
    mkswap /swapfile
    swapon /swapfile
    echo '/swapfile none swap sw 0 0' >> /etc/fstab
    echo 'vm.swappiness=10' >> /etc/sysctl.conf
    sysctl -p

    # ── Docker ────────────────────────────────────────────────────────────
    curl -fsSL https://get.docker.com | sh
    usermod -aG docker ubuntu
    systemctl enable docker && systemctl start docker

    # ── Tailscale ─────────────────────────────────────────────────────────
    curl -fsSL https://tailscale.com/install.sh | sh
    tailscale up --authkey=${var.tailscale_auth_key} --hostname=gcp-gateway --accept-routes
    systemctl enable tailscaled

    # Wait for Tailscale
    sleep 10

    # ── App stack ─────────────────────────────────────────────────────────
    # Uptime Kuma moved to OCI Micro #2 (same VCN as A1, lower latency)
    mkdir -p /opt/gateway/{nginx/data,nginx/letsencrypt}
    chown -R ubuntu:ubuntu /opt/gateway

    cat > /opt/gateway/docker-compose.yml << 'COMPOSE'
    version: '3.8'

    services:

      # Nginx Proxy Manager — sole service on GCP
      # Routes: Cloudflare → GCP (public IP) → NPM → OCI A1 via Tailscale
      nginx-proxy:
        image: jc21/nginx-proxy-manager:latest
        container_name: nginx-proxy
        restart: unless-stopped
        ports:
          - "80:80"
          - "443:443"
          - "127.0.0.1:81:81"    # Admin UI — localhost only (access via Tailscale)
        volumes:
          - ./nginx/data:/data
          - ./nginx/letsencrypt:/etc/letsencrypt
        environment:
          DB_SQLITE_FILE: "/data/database.sqlite"
    COMPOSE

    cd /opt/gateway
    docker compose up -d

    # ── UFW ───────────────────────────────────────────────────────────────
    ufw default deny incoming
    ufw default allow outgoing
    ufw allow 80/tcp
    ufw allow 443/tcp
    ufw allow 41641/udp
    ufw --force enable

    echo "Gateway bootstrap complete"
  EOF
}
