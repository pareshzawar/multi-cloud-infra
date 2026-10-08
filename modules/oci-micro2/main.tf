###############################################################################
# modules/oci-micro2/main.tf
#
# OCI VM.Standard.E2.1.Micro — Always Free AMD instance #2
# Role: Ops & Monitoring node
#   - Uptime Kuma      (moved from GCP — monitors all 5 nodes)
#   - Portainer CE     (Docker GUI for managing A1 + this instance remotely)
#   - Watchtower       (auto-updates the containers on THIS host)
#   - Fail2ban         (local SSH protection)
#
# Network: same OCI VCN private subnet as Ampere A1
#   → No public IP assigned
#   → Admin UIs listen on 127.0.0.1 only and are published to the tailnet with
#     `tailscale serve` (HTTPS, MagicDNS name). Requires "HTTPS certificates"
#     to be enabled in the Tailscale admin console.
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
    # user_data changes force replacement (blocked by prevent_destroy).
    ignore_changes = [source_details[0].source_id, metadata["user_data"]]
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
    # No ufw: it declares "Breaks: iptables-persistent", and OCI images rely
    # on iptables-persistent. With `set -e`, installing both aborted the
    # whole bootstrap at this line.
    apt-get install -y curl wget git fail2ban unattended-upgrades \
                       iptables-persistent netfilter-persistent

    # ── OCI host firewall (iptables) — required in addition to the NSG ───
    # Only Tailscale needs an inbound port; admin UIs are served over the
    # tailnet by tailscaled itself.
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
      --accept-routes
    # (--advertise-tags removed: it fails unless the tailnet ACL defines
    # tagOwners for tag:ops, and with set -e that aborted the bootstrap.)
    systemctl enable tailscaled
    sleep 8

    # ── App directories ───────────────────────────────────────────────────
    mkdir -p /opt/ops/uptime-kuma /opt/ops/portainer
    chown -R ubuntu:ubuntu /opt/ops

    # ── Docker Compose ────────────────────────────────────────────────────
    cat > /opt/ops/docker-compose.yml << 'COMPOSE'
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
        # Localhost only — published to the tailnet by `tailscale serve` below
        ports:
          - "127.0.0.1:3001:3001"
        volumes:
          - ./uptime-kuma:/app/data
        environment:
          - NODE_EXTRA_CA_CERTS=/etc/ssl/certs/ca-certificates.crt

      # ── Portainer CE ────────────────────────────────────────────────────
      # Docker GUI — manages THIS host via the local socket, and A1 via the
      # Portainer agent running on A1 (<a1_private_ip>:9001).
      # (Previously a local agent also published host port 9001, which
      # clashed with the server's own 9001 mapping, so one failed to start.)
      # Version pinned to match the agent image on A1.
      portainer:
        image: portainer/portainer-ce:2.21.5
        container_name: portainer
        restart: unless-stopped
        networks: [ops-internal]
        ports:
          - "127.0.0.1:9000:9000"    # UI — localhost; tailnet via tailscale serve
        volumes:
          - /var/run/docker.sock:/var/run/docker.sock
          - ./portainer:/data
        command: --admin-password-file /data/admin_password

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
          # Notifications are off: Gmail SMTP needs a username + app password,
          # which must not be inlined here. To enable, set
          # WATCHTOWER_NOTIFICATION_URL (shoutrrr format) from a secret file.
          TZ: "Asia/Kolkata"

    COMPOSE

    # ── Generate Portainer initial admin password (plain text file) ──────
    # Read it once with: sudo cat /opt/ops/portainer/admin_password
    # (No longer echoed into the bootstrap log.)
    (umask 077 && openssl rand -base64 24 > /opt/ops/portainer/admin_password)

    # ── Start ops stack ───────────────────────────────────────────────────
    cd /opt/ops
    docker compose up -d

    # ── Publish admin UIs to the tailnet (HTTPS, tailnet members only) ────
    #   https://oci-micro2-ops.<tailnet>.ts.net/       → Uptime Kuma
    #   https://oci-micro2-ops.<tailnet>.ts.net:8443/  → Portainer
    # Needs MagicDNS + HTTPS enabled for the tailnet; don't abort if not.
    tailscale serve --bg --https=443  http://127.0.0.1:3001 || echo "WARN: enable HTTPS in Tailscale, then re-run tailscale serve"
    tailscale serve --bg --https=8443 http://127.0.0.1:9000 || echo "WARN: enable HTTPS in Tailscale, then re-run tailscale serve"

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

    # ── Fail2ban ──────────────────────────────────────────────────────────
    systemctl enable fail2ban && systemctl start fail2ban

    echo "OCI Micro #2 ops bootstrap complete."
  EOF
}
