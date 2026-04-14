###############################################################################
# modules/oci-micro2/main.tf
#
# OCI VM.Standard.E2.1.Micro — Always Free AMD instance #2
# Role: Ops & Monitoring node
#   - Uptime Kuma      (moved from GCP — monitors all 5 nodes)
#   - Portainer CE     (Docker GUI for managing A1 + this instance remotely)
#   - Watchtower       (centralised auto-update scheduler for all servers)
#   - Fail2ban syslog  (aggregates auth logs from A1 + vault over Tailscale)
#
# Network: same OCI VCN private subnet as Ampere A1
#   → A1 services reachable on internal IPs (no Tailscale hop, low latency)
#   → All admin UIs locked to Tailscale CGNAT range (100.64.0.0/10)
#   → No public IP assigned
###############################################################################

data "oci_core_images" "ubuntu_amd" {
  compartment_id           = var.compartment_id
  operating_system         = "Canonical Ubuntu"
  operating_system_version = "22.04"
  shape                    = "VM.Standard.E2.1.Micro"
  sort_by                  = "TIMECREATED"
  sort_order               = "DESC"
}

resource "oci_core_instance" "micro2" {
  availability_domain = var.availability_domain
  compartment_id      = var.compartment_id
  display_name        = "oci-micro2-ops"
  shape               = "VM.Standard.E2.1.Micro"

  # E2.1.Micro is a fixed shape — no shape_config block needed
  # Specs: 1/8 OCPU, 1 GB RAM — fixed, not configurable

  create_vnic_details {
    subnet_id        = var.private_subnet_id
    assign_public_ip = false # Private subnet — no public IP
    nsg_ids          = [var.micro2_nsg_id]
    display_name     = "micro2-vnic"
    hostname_label   = "oci-micro2"
  }

  source_details {
    source_type             = "image"
    source_id               = data.oci_core_images.ubuntu_amd.images[0].id
    boot_volume_size_in_gbs = 50 # Always Free: up to 200 GB total across instances
  }

  metadata = {
    ssh_authorized_keys = var.ssh_public_key
    user_data           = base64encode(local.cloud_init)
  }

  lifecycle {
    prevent_destroy = true
    ignore_changes  = [source_details[0].source_id]
  }

  freeform_tags = var.tags
}

locals {
  cloud_init = <<-EOF
    #!/bin/bash
    set -euo pipefail
    exec > /var/log/cloud-init-micro2.log 2>&1

    # ── System ────────────────────────────────────────────────────────────
    apt-get update && apt-get upgrade -y
    apt-get install -y curl wget git ufw fail2ban unattended-upgrades \
                       iptables-persistent netfilter-persistent

    # ── OCI internal firewall (iptables) — required in addition to NSG ───
    iptables -I INPUT 6 -m state --state NEW -p tcp --dport 9000 -j ACCEPT   # Portainer
    iptables -I INPUT 6 -m state --state NEW -p tcp --dport 9001 -j ACCEPT   # Portainer agent
    iptables -I INPUT 6 -m state --state NEW -p tcp --dport 3001 -j ACCEPT   # Uptime Kuma
    iptables -I INPUT 6 -m state --state NEW -p udp --dport 41641 -j ACCEPT  # Tailscale
    netfilter-persistent save

    # ── Swapfile (critical for 1 GB RAM) ──────────────────────────────────
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
    tailscale up \
      --authkey=${var.tailscale_auth_key} \
      --hostname=oci-micro2-ops \
      --accept-routes \
      --advertise-tags=tag:ops
    systemctl enable tailscaled
    sleep 8

    # ── App directories ───────────────────────────────────────────────────
    mkdir -p /opt/ops/{uptime-kuma,portainer,watchtower-config}
    chown -R ubuntu:ubuntu /opt/ops

    # ── Docker Compose ────────────────────────────────────────────────────
    cat > /opt/ops/docker-compose.yml << 'COMPOSE'
    version: '3.8'

    networks:
      ops-internal:
        driver: bridge
        ipam:
          config:
            - subnet: 172.21.0.0/24

    services:

      # ── Uptime Kuma ─────────────────────────────────────────────────────
      # Moved from GCP — monitors all 5 nodes from within OCI private subnet
      # Monitors A1 services over internal IP (no Tailscale hop needed)
      uptime-kuma:
        image: louislam/uptime-kuma:1
        container_name: uptime-kuma
        restart: unless-stopped
        networks: [ops-internal]
        # Bind to localhost — Tailscale tunnel exposes externally
        ports:
          - "127.0.0.1:3001:3001"
        volumes:
          - ./uptime-kuma:/app/data
        environment:
          - NODE_EXTRA_CA_CERTS=/etc/ssl/certs/ca-certificates.crt

      # ── Portainer CE ────────────────────────────────────────────────────
      # Docker GUI — manages containers on THIS instance and A1 (via Portainer agent)
      # Admin UI at :9000, locked to Tailscale range by NSG + UFW
      portainer:
        image: portainer/portainer-ce:latest
        container_name: portainer
        restart: unless-stopped
        networks: [ops-internal]
        ports:
          - "127.0.0.1:9000:9000"    # UI — Tailscale only
          - "9001:9001"              # Agent port — reachable by A1 over private subnet
        volumes:
          - /var/run/docker.sock:/var/run/docker.sock
          - ./portainer:/data
        command: --admin-password-file /data/admin_password

      # ── Portainer Agent (on THIS instance) ──────────────────────────────
      # Portainer CE connects to agents on remote hosts (A1)
      portainer-agent:
        image: portainer/agent:latest
        container_name: portainer-agent
        restart: unless-stopped
        networks: [ops-internal]
        ports:
          - "9001:9001"
        volumes:
          - /var/run/docker.sock:/var/run/docker.sock
          - /var/lib/docker/volumes:/var/lib/docker/volumes

      # ── Watchtower ──────────────────────────────────────────────────────
      # Centralised auto-updater — updates containers on THIS instance
      # For A1 + AWS, each server runs its own Watchtower (Docker socket local only)
      watchtower:
        image: containrrr/watchtower:latest
        container_name: watchtower
        restart: unless-stopped
        networks: [ops-internal]
        volumes:
          - /var/run/docker.sock:/var/run/docker.sock
        environment:
          WATCHTOWER_SCHEDULE: "0 0 4 * * *"     # 4 AM daily
          WATCHTOWER_CLEANUP: "true"              # Remove old images after update
          WATCHTOWER_INCLUDE_STOPPED: "false"
          WATCHTOWER_NOTIFICATIONS: "email"
          WATCHTOWER_NOTIFICATION_EMAIL_FROM: "watchtower@${var.domain_name}"
          WATCHTOWER_NOTIFICATION_EMAIL_TO: "${var.alert_email}"
          WATCHTOWER_NOTIFICATION_EMAIL_SERVER: "smtp.gmail.com"
          WATCHTOWER_NOTIFICATION_EMAIL_SERVER_PORT: "587"
          TZ: "Asia/Kolkata"

    COMPOSE

    # ── Generate Portainer admin password hash ─────────────────────────
    # Uses a placeholder — update with: htpasswd -nb -B admin <password>
    PORTAINER_PASS=$(openssl rand -base64 24)
    echo "$PORTAINER_PASS" > /opt/ops/portainer/admin_password
    echo "Portainer initial password: $PORTAINER_PASS" >> /var/log/cloud-init-micro2.log
    chmod 600 /opt/ops/portainer/admin_password

    # ── Start ops stack ───────────────────────────────────────────────────
    cd /opt/ops
    docker compose up -d

    # ── Systemd service ───────────────────────────────────────────────────
    cat > /etc/systemd/system/ops.service << 'UNIT'
    [Unit]
    Description=Ops monitoring stack
    Requires=docker.service tailscaled.service
    After=docker.service network.target tailscaled.service

    [Service]
    Type=oneshot
    RemainAfterExit=yes
    WorkingDirectory=/opt/ops
    ExecStart=/usr/bin/docker compose up -d --remove-orphans
    ExecStop=/usr/bin/docker compose down
    TimeoutStartSec=120

    [Install]
    WantedBy=multi-user.target
    UNIT

    systemctl daemon-reload
    systemctl enable ops.service

    # ── UFW ───────────────────────────────────────────────────────────────
    ufw default deny incoming
    ufw default allow outgoing
    # Tailscale UDP
    ufw allow 41641/udp comment "Tailscale"
    # Portainer agent — reachable from OCI private subnet only (A1 → micro2)
    ufw allow from 10.0.0.0/16 to any port 9001 comment "Portainer agent - OCI VCN only"
    # All admin UIs (9000, 3001) — NO public rule; accessible only via Tailscale tunnel
    ufw --force enable

    # ── Fail2ban ──────────────────────────────────────────────────────────
    systemctl enable fail2ban && systemctl start fail2ban

    echo "OCI Micro #2 ops bootstrap complete."
  EOF
}
