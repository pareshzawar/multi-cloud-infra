###############################################################################
# modules/oci-compute2/main.tf
#
# Second OCI tenancy — TWO AMD E2.1.Micro instances
# Each OCI tenancy gets 2x E2.1.Micro Always Free — this module provisions both.
#
# micro-a: general overflow / n8n worker / cron jobs
# micro-b: Terraform runner (deploy-from-server, no laptop needed)
#
# Both instances:
#   - Join the same Tailscale mesh as Tenancy 1
#   - Ubuntu 22.04 LTS (AMD x86)
#   - 1 OCPU / 1 GB RAM each
#   - 50 GB boot volume each
#   - Public IP (different VCN from Tenancy 1)
#
# Provider alias usage in environments/prod/main.tf:
#
#   provider "oci" {
#     alias        = "tenancy2"
#     tenancy_ocid = var.oci2_tenancy_ocid
#     user_ocid    = var.oci2_user_ocid
#     fingerprint  = var.oci2_fingerprint
#     private_key  = file("~/.oci/oci_api_key_2.pem")
#     region       = var.oci2_region
#   }
#
#   module "oci2_compute" {
#     source    = "../../modules/oci-compute2"
#     providers = { oci = oci.tenancy2 }
#     ...
#   }
###############################################################################

terraform {
  required_providers {
    oci = { source = "oracle/oci" }
  }
}

data "oci_core_images" "ubuntu_amd" {
  compartment_id           = var.compartment_id
  operating_system         = "Canonical Ubuntu"
  operating_system_version = "22.04"
  shape                    = "VM.Standard.E2.1.Micro"
  sort_by                  = "TIMECREATED"
  sort_order               = "DESC"
}

# ── Minimal VCN for Tenancy 2 ─────────────────────────────────────────────────

resource "oci_core_vcn" "tenancy2" {
  compartment_id = var.compartment_id
  cidr_blocks    = ["10.1.0.0/16"]
  display_name   = "tenancy2-vcn"
  dns_label      = "tenancy2"
  freeform_tags  = var.tags
}

resource "oci_core_internet_gateway" "tenancy2" {
  compartment_id = var.compartment_id
  vcn_id         = oci_core_vcn.tenancy2.id
  enabled        = true
  display_name   = "tenancy2-igw"
  freeform_tags  = var.tags
}

resource "oci_core_route_table" "tenancy2" {
  compartment_id = var.compartment_id
  vcn_id         = oci_core_vcn.tenancy2.id
  display_name   = "tenancy2-rt"
  route_rules {
    destination       = "0.0.0.0/0"
    destination_type  = "CIDR_BLOCK"
    network_entity_id = oci_core_internet_gateway.tenancy2.id
  }
  freeform_tags = var.tags
}

resource "oci_core_security_list" "tenancy2" {
  compartment_id = var.compartment_id
  vcn_id         = oci_core_vcn.tenancy2.id
  display_name   = "tenancy2-sl"

  ingress_security_rules {
    protocol  = "6"
    source    = "0.0.0.0/0"
    stateless = false
    tcp_options {
      min = 22
      max = 22
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
  egress_security_rules {
    protocol    = "all"
    destination = "0.0.0.0/0"
    stateless   = false
  }
  freeform_tags = var.tags
}

resource "oci_core_subnet" "tenancy2" {
  compartment_id             = var.compartment_id
  vcn_id                     = oci_core_vcn.tenancy2.id
  cidr_block                 = "10.1.1.0/24"
  display_name               = "tenancy2-subnet"
  dns_label                  = "t2subnet"
  prohibit_public_ip_on_vnic = false
  route_table_id             = oci_core_route_table.tenancy2.id
  security_list_ids          = [oci_core_security_list.tenancy2.id]
  freeform_tags              = var.tags
}

# ── Micro A — General overflow / n8n worker ───────────────────────────────────

resource "oci_core_instance" "micro_a" {
  availability_domain = var.availability_domain
  compartment_id      = var.compartment_id
  display_name        = "tenancy2-micro-a"
  shape               = "VM.Standard.E2.1.Micro"

  create_vnic_details {
    subnet_id        = oci_core_subnet.tenancy2.id
    assign_public_ip = true
    display_name     = "micro-a-vnic"
    hostname_label   = "micro-a"
  }

  source_details {
    source_type             = "image"
    source_id               = data.oci_core_images.ubuntu_amd.images[0].id
    boot_volume_size_in_gbs = 50
  }

  metadata = {
    ssh_authorized_keys = var.ssh_public_key
    user_data           = base64encode(local.cloud_init_micro_a)
  }

  lifecycle {
    prevent_destroy = true
    ignore_changes  = [source_details[0].source_id]
  }
  freeform_tags = merge(var.tags, { role = "overflow-worker" })
}

# ── Micro B — Terraform runner / deployment server ────────────────────────────
# This instance runs terraform apply so you don't need your laptop at all.
# Access via Tailscale → SSH → run terraform from here.

resource "oci_core_instance" "micro_b" {
  availability_domain = var.availability_domain
  compartment_id      = var.compartment_id
  display_name        = "tenancy2-micro-b-vault-standby"
  shape               = "VM.Standard.E2.1.Micro"

  create_vnic_details {
    subnet_id        = oci_core_subnet.tenancy2.id
    assign_public_ip = true
    display_name     = "micro-b-vnic"
    hostname_label   = "micro-b"
  }

  source_details {
    source_type             = "image"
    source_id               = data.oci_core_images.ubuntu_amd.images[0].id
    boot_volume_size_in_gbs = 50
  }

  metadata = {
    ssh_authorized_keys = var.ssh_public_key
    user_data           = base64encode(local.cloud_init_micro_b)
  }

  lifecycle {
    prevent_destroy = true
    ignore_changes  = [source_details[0].source_id]
  }
  freeform_tags = merge(var.tags, { role = "terraform-deployer" })
}

# ── Cloud-init: Micro A (overflow worker) ────────────────────────────────────

locals {
  cloud_init_micro_a = <<-EOF
    #!/bin/bash
    set -euo pipefail
    exec > /var/log/cloud-init-micro-a.log 2>&1

    apt-get update && apt-get upgrade -y
    apt-get install -y curl wget git ufw fail2ban unattended-upgrades \
                       iptables-persistent netfilter-persistent

    # OCI iptables (must open in addition to security list)
    iptables -I INPUT 6 -m state --state NEW -p tcp  --dport 22    -j ACCEPT
    iptables -I INPUT 6 -m state --state NEW -p udp  --dport 41641 -j ACCEPT
    netfilter-persistent save

    # Swapfile (critical for 1 GB RAM)
    fallocate -l 2G /swapfile && chmod 600 /swapfile
    mkswap /swapfile && swapon /swapfile
    echo '/swapfile none swap sw 0 0' >> /etc/fstab
    echo 'vm.swappiness=10' >> /etc/sysctl.conf && sysctl -p

    # Docker
    curl -fsSL https://get.docker.com | sh
    usermod -aG docker ubuntu
    systemctl enable docker && systemctl start docker

    # Tailscale — joins the SAME mesh as Tenancy 1
    curl -fsSL https://tailscale.com/install.sh | sh
    tailscale up --authkey=${var.tailscale_auth_key} \
                 --hostname=oci2-micro-a \
                 --accept-routes
    systemctl enable tailscaled

    # UFW
    ufw default deny incoming && ufw default allow outgoing
    ufw allow 22/tcp && ufw allow 41641/udp
    ufw --force enable
    systemctl enable fail2ban && systemctl start fail2ban

    echo "Micro A bootstrap complete"
  EOF

  # ── Cloud-init: Micro B ───────────────────────────────────────────────────
  # Role: Vaultwarden STANDBY + Webhook relay + Rclone backup aggregator
  #
  # STANDBY MODE (default):
  #   - Vaultwarden installed but NOT started (standby only)
  #   - Data dir synced nightly from AWS vault via rclone over Tailscale
  #   - Ready to promote to PRIMARY when AWS free tier expires
  #
  # ACTIVE MODE (after migration — see VAULT_MIGRATION.md):
  #   - Start Vaultwarden: docker compose up -d vaultwarden
  #   - Update DNS vault.yourdomain.com → this server's Tailscale IP
  #   - Disable sync cron (no longer pulling from AWS)
  #
  # Webhook relay:
  #   - Receives public inbound webhooks (GitHub, Telegram, Stripe etc.)
  #   - Forwards to n8n on OCI A1 via Tailscale (keeps n8n off public internet)
  #
  # Rclone backup aggregator:
  #   - Pulls /opt/vaultwarden/data from AWS nightly
  #   - Pushes all backups to OCI Object Storage (Tenancy 2 free tier, 10 GB)

  cloud_init_micro_b = <<-EOF
    #!/bin/bash
    set -euo pipefail
    exec > /var/log/cloud-init-micro-b.log 2>&1

    # ── System ─────────────────────────────────────────────────────────────
    apt-get update && apt-get upgrade -y
    apt-get install -y curl wget git ufw fail2ban unattended-upgrades \
                       iptables-persistent netfilter-persistent python3-pip

    # ── OCI iptables (required alongside Security List) ────────────────────
    iptables -I INPUT 6 -m state --state NEW -p tcp  --dport 22    -j ACCEPT
    iptables -I INPUT 6 -m state --state NEW -p tcp  --dport 8080  -j ACCEPT
    iptables -I INPUT 6 -m state --state NEW -p tcp  --dport 9000  -j ACCEPT
    iptables -I INPUT 6 -m state --state NEW -p udp  --dport 41641 -j ACCEPT
    netfilter-persistent save

    # ── Swapfile (critical for 1 GB RAM) ───────────────────────────────────
    fallocate -l 2G /swapfile && chmod 600 /swapfile
    mkswap /swapfile && swapon /swapfile
    echo '/swapfile none swap sw 0 0' >> /etc/fstab
    echo 'vm.swappiness=10' >> /etc/sysctl.conf && sysctl -p

    # ── Docker ─────────────────────────────────────────────────────────────
    curl -fsSL https://get.docker.com | sh
    usermod -aG docker ubuntu
    systemctl enable docker && systemctl start docker

    # ── Rclone (for nightly sync from AWS + backup to OCI Object Storage) ──
    curl https://rclone.org/install.sh | bash
    mkdir -p /home/ubuntu/.config/rclone
    # NOTE: configure rclone manually after deploy:
    #   rclone config
    #   Add remote "aws_vault"  → S3 → your AWS credentials
    #   Add remote "oci_backup" → S3-compatible → OCI Object Storage credentials
    cat > /home/ubuntu/.config/rclone/rclone.conf << 'RCLONE'
    # Placeholder — run "rclone config" to set up:
    #   1. "aws_vault"  — S3 remote pointing to your vaultwarden-backup bucket
    #   2. "oci_backup" — OCI Object Storage S3-compatible endpoint
    RCLONE
    chown -R ubuntu:ubuntu /home/ubuntu/.config/rclone

    # ── App directories ─────────────────────────────────────────────────────
    mkdir -p /opt/vaultwarden/data
    mkdir -p /opt/webhook-relay
    chown -R ubuntu:ubuntu /opt/vaultwarden /opt/webhook-relay

    # ── Docker Compose — all services ───────────────────────────────────────
    cat > /opt/vaultwarden/docker-compose.yml << 'COMPOSE'
    version: '3.8'

    services:

      # ── Vaultwarden (STANDBY — do NOT start until migration) ─────────────
      # Start with: docker compose up -d vaultwarden
      # Stop with:  docker compose stop vaultwarden
      vaultwarden:
        image: vaultwarden/server:latest
        container_name: vaultwarden
        restart: "no"          # STANDBY: manual start only. Change to unless-stopped after migration.
        environment:
          ROCKET_ADDRESS: "127.0.0.1"  # localhost only until migration — then change to Tailscale IP
          ROCKET_PORT: "8080"
          DOMAIN: "https://vault.${var.domain_name}"
          SIGNUPS_ALLOWED: "false"
          WEBSOCKET_ENABLED: "true"
          LOG_LEVEL: "warn"
        volumes:
          - ./data:/data
        ports:
          - "127.0.0.1:8080:80"    # localhost only in standby — change to TS_IP:8080:80 after migration

      # ── Webhook relay ────────────────────────────────────────────────────
      # Receives public webhooks, forwards to n8n on OCI A1 via Tailscale
      # Keeps n8n off the public internet entirely
      webhook-relay:
        image: nicholaswilde/webhook-relay:latest
        container_name: webhook-relay
        restart: unless-stopped
        environment:
          RELAY_TARGET: "http://${var.n8n_tailscale_ip}:5678"  # n8n on OCI A1
          RELAY_SECRET: ""                                       # Set a shared secret
          PORT: "9000"
        ports:
          - "0.0.0.0:9000:9000"   # Public — receives inbound webhooks
    COMPOSE

    # ── Nightly sync scripts ─────────────────────────────────────────────────

    # Script 1: Pull Vaultwarden data from AWS → this server (keeps standby fresh)
    cat > /opt/vaultwarden/sync-from-aws.sh << 'SYNC'
    #!/bin/bash
    # Syncs Vaultwarden data from AWS vault to this standby instance
    # Run nightly while in STANDBY mode
    # DISABLE THIS CRON after migration to active
    set -euo pipefail
    LOG="/var/log/vault-sync.log"
    echo "[$(date)] Starting vault sync from AWS" >> $LOG

    # Stop vaultwarden if running (prevents partial reads)
    docker compose -f /opt/vaultwarden/docker-compose.yml stop vaultwarden 2>/dev/null || true

    # Pull latest data from AWS S3 backup bucket
    rclone sync aws_vault:vaultwarden-backup-ACCOUNT_ID /opt/vaultwarden/data/ \
      --log-file=$LOG --log-level INFO

    echo "[$(date)] Vault sync complete" >> $LOG
    SYNC
    chmod +x /opt/vaultwarden/sync-from-aws.sh

    # Script 2: Push all backups to OCI Object Storage (offsite copy)
    cat > /opt/vaultwarden/backup-to-oci.sh << 'BACKUP'
    #!/bin/bash
    # Pushes local vault data to OCI Object Storage as an offsite backup
    # Runs nightly regardless of standby/active mode
    set -euo pipefail
    DATE=$(date +%Y-%m-%d-%H%M)
    LOG="/var/log/vault-backup-oci.log"
    BACKUP_FILE="/tmp/vault-backup-$DATE.tar.gz"

    tar -czf "$BACKUP_FILE" /opt/vaultwarden/data/ 2>/dev/null || true
    rclone copy "$BACKUP_FILE" oci_backup:vault-backups/ \
      --log-file=$LOG --log-level INFO
    rm -f "$BACKUP_FILE"
    echo "[$(date)] OCI backup complete: $DATE" >> $LOG
    BACKUP
    chmod +x /opt/vaultwarden/backup-to-oci.sh

    # ── Cron jobs ───────────────────────────────────────────────────────────
    (crontab -u ubuntu -l 2>/dev/null; cat << 'CRON'
    # Sync Vaultwarden data from AWS nightly at 01:00 UTC (STANDBY MODE)
    # Comment this out after migration to active
    0 1 * * * /opt/vaultwarden/sync-from-aws.sh >> /var/log/vault-sync.log 2>&1

    # Backup to OCI Object Storage nightly at 02:00 UTC (always runs)
    0 2 * * * /opt/vaultwarden/backup-to-oci.sh >> /var/log/vault-backup-oci.log 2>&1
    CRON
    ) | crontab -u ubuntu -

    # ── Tailscale ───────────────────────────────────────────────────────────
    curl -fsSL https://tailscale.com/install.sh | sh
    tailscale up --authkey=${var.tailscale_auth_key} \
                 --hostname=oci2-micro-b-vault-standby \
                 --accept-routes
    systemctl enable tailscaled
    sleep 8

    # Start webhook relay (always running)
    cd /opt/vaultwarden
    docker compose up -d webhook-relay

    # ── UFW ─────────────────────────────────────────────────────────────────
    ufw default deny incoming
    ufw default allow outgoing
    ufw allow 22/tcp    comment "SSH"
    ufw allow 41641/udp comment "Tailscale"
    ufw allow 9000/tcp  comment "Webhook relay"
    # NOTE: Port 8080 (Vaultwarden) is NOT opened publicly.
    # After migration: open 8080 via Tailscale only (not UFW public rule)
    ufw --force enable

    systemctl enable fail2ban && systemctl start fail2ban

    echo "Micro B bootstrap complete."
    echo "Role: Vaultwarden STANDBY + Webhook relay + Rclone backup aggregator"
    echo "Next step: run 'rclone config' to set up aws_vault and oci_backup remotes"
  EOF
}
