###############################################################################
# modules/oci-compute2/main.tf
#
# Second OCI tenancy — TWO AMD E2.1.Micro instances
# Each OCI tenancy gets 2x E2.1.Micro Always Free — this module provisions both.
#
# micro-a: general overflow worker / cron jobs
# micro-b: Vaultwarden standby + nightly backup aggregator
#
# Both instances:
#   - Join the same Tailscale mesh as Tenancy 1
#   - Ubuntu 22.04 LTS (AMD x86)
#   - 1/8 OCPU (burstable) / 1 GB RAM each
#   - 50 GB boot volume each
#   - Public IP (different VCN from Tenancy 1); SSH + Tailscale only
#
# Provider alias usage in environments/prod/main.tf:
#
#   provider "oci" {
#     alias        = "tenancy2"
#     tenancy_ocid = var.oci2_tenancy_ocid
#     user_ocid    = var.oci2_user_ocid
#     fingerprint  = var.oci2_fingerprint
#     private_key  = var.oci2_private_key   # PEM contents via TF_VAR_*
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
    # user_data changes force replacement (blocked by prevent_destroy).
    ignore_changes = [source_details[0].source_id, metadata["user_data"]]
  }
  freeform_tags = merge(var.tags, { role = "overflow-worker" })
}

# ── Micro B — Vaultwarden standby + backup aggregator ─────────────────────────
# See the cloud_init_micro_b comment below for the promote-to-active steps.

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
    # user_data changes force replacement (blocked by prevent_destroy).
    ignore_changes = [source_details[0].source_id, metadata["user_data"]]
  }
  freeform_tags = merge(var.tags, { role = "vault-standby" })
}

# ── Cloud-init: Micro A (overflow worker) ────────────────────────────────────

locals {
  cloud_init_micro_a = <<-EOF
    #!/bin/bash
    set -euo pipefail
    exec > /var/log/cloud-init-micro-a.log 2>&1

    apt-get update && apt-get upgrade -y
    # No ufw: it declares "Breaks: iptables-persistent" (which OCI images use),
    # so installing both made apt — and, with set -e, this script — fail.
    apt-get install -y curl wget git fail2ban unattended-upgrades \
                       iptables-persistent netfilter-persistent

    # OCI host firewall (must be opened in addition to the security list)
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

    systemctl enable fail2ban && systemctl start fail2ban

    echo "Micro A bootstrap complete"
  EOF

  # ── Cloud-init: Micro B ───────────────────────────────────────────────────
  # Role: Vaultwarden STANDBY + backup aggregator
  #
  # STANDBY MODE (default):
  #   - Vaultwarden defined but NOT started
  #   - Nightly: newest DB snapshot pulled from the AWS S3 backup bucket
  #   - Ready to promote to PRIMARY when the AWS free tier ends
  #
  # PROMOTE TO ACTIVE:
  #   cd /opt/vaultwarden && docker compose up -d vaultwarden
  #   sudo tailscale serve --bg http://127.0.0.1:8080
  #   → https://oci2-micro-b-vault-standby.<tailnet>.ts.net (tailnet only)
  #   then remove the 01:00 sync line from `crontab -u ubuntu -e`
  #
  # Backup aggregator: nightly tarball of the data dir → OCI Object Storage.
  #
  # (A public "webhook relay" container used to live here. It was removed: its
  #  image was unverified, it ran with an empty shared secret, and port 9000
  #  was never opened in the security list, so it could not have worked.)

  cloud_init_micro_b = <<-EOF
    #!/bin/bash
    set -euo pipefail
    exec > /var/log/cloud-init-micro-b.log 2>&1

    # ── System ─────────────────────────────────────────────────────────────
    apt-get update && apt-get upgrade -y
    # No ufw — see micro A above.
    apt-get install -y curl wget git fail2ban unattended-upgrades \
                       iptables-persistent netfilter-persistent python3

    # ── OCI host firewall (required alongside the security list) ───────────
    # Vaultwarden is never exposed on a host port beyond localhost; tailnet
    # access goes through tailscaled (`tailscale serve`), so only SSH and
    # Tailscale need inbound rules.
    iptables -I INPUT 6 -m state --state NEW -p tcp  --dport 22    -j ACCEPT
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

    # ── Tailscale ───────────────────────────────────────────────────────────
    curl -fsSL https://tailscale.com/install.sh | sh
    tailscale up --authkey=${var.tailscale_auth_key} \
                 --hostname=oci2-micro-b-vault-standby \
                 --accept-routes
    systemctl enable tailscaled
    sleep 8

    # ── Rclone (pull from AWS S3, push to OCI Object Storage) ──────────────
    curl -fsSL https://rclone.org/install.sh | bash
    install -d -o ubuntu -g ubuntu /home/ubuntu/.config /home/ubuntu/.config/rclone
    # NOTE: configure rclone manually after deploy (as ubuntu): rclone config
    #   1. "aws_vault"  — S3 remote with read access to ${var.backup_bucket_name}
    #   2. "oci_backup" — OCI Object Storage S3-compatible endpoint
    touch /home/ubuntu/.config/rclone/rclone.conf
    chown ubuntu:ubuntu /home/ubuntu/.config/rclone/rclone.conf

    # ── App directories + log files (cron runs as ubuntu, not root) ─────────
    mkdir -p /opt/vaultwarden/data
    chown -R ubuntu:ubuntu /opt/vaultwarden
    touch /var/log/vault-sync.log /var/log/vault-backup-oci.log
    chown ubuntu:ubuntu /var/log/vault-sync.log /var/log/vault-backup-oci.log

    # ── Vaultwarden public URL = this node's MagicDNS name (HTTPS) ──────────
    # Vaultwarden's web vault needs HTTPS; tailscale serve provides it.
    TS_DNS=$(tailscale status --json | python3 -c 'import json,sys; print(json.load(sys.stdin)["Self"]["DNSName"].rstrip("."))')
    echo "VW_DOMAIN=https://$${TS_DNS}" > /opt/vaultwarden/.env

    # ── Docker Compose ──────────────────────────────────────────────────────
    cat > /opt/vaultwarden/docker-compose.yml << 'COMPOSE'
    services:
      # STANDBY — do NOT start until migration (see header for the steps)
      vaultwarden:
        image: vaultwarden/server:1.32.7
        container_name: vaultwarden
        restart: "no"           # change to unless-stopped after promotion
        environment:
          # Vaultwarden listens on 0.0.0.0:80 INSIDE the container (default).
          # Setting ROCKET_ADDRESS to a host IP made it unreachable.
          DOMAIN: "$${VW_DOMAIN}"
          SIGNUPS_ALLOWED: "false"
          LOG_LEVEL: "warn"
        volumes:
          - ./data:/data
        ports:
          - "127.0.0.1:8080:80"   # host 8080 → container 80; tailscale serve proxies it
    COMPOSE

    # ── Nightly sync scripts ─────────────────────────────────────────────────

    # Script 1: restore the newest AWS DB snapshot into the standby data dir.
    # The AWS bucket holds dated files (db-YYYY-MM-DD.sqlite3), not a data
    # directory, so copy the newest one to db.sqlite3 — a blind `rclone sync`
    # would have deleted everything else in data/.
    cat > /opt/vaultwarden/sync-from-aws.sh << 'SYNC'
    #!/bin/bash
    set -euo pipefail
    BUCKET="${var.backup_bucket_name}"
    echo "[$(date)] Starting vault sync from s3://$BUCKET"

    # Stop vaultwarden if running (prevents writing while we replace the DB)
    docker compose -f /opt/vaultwarden/docker-compose.yml stop vaultwarden 2>/dev/null || true

    LATEST=$(rclone lsf "aws_vault:$BUCKET" --include 'db-*.sqlite3' | sort | tail -n 1)
    if [ -z "$LATEST" ]; then
      echo "[$(date)] No db-*.sqlite3 snapshot found — nothing to do"
      exit 1
    fi
    rclone copyto "aws_vault:$BUCKET/$LATEST" /opt/vaultwarden/data/db.sqlite3
    echo "[$(date)] Restored $LATEST"
    SYNC
    chmod +x /opt/vaultwarden/sync-from-aws.sh

    # Script 2: push a tarball of the data dir to OCI Object Storage.
    # Errors are no longer swallowed (a failed tar used to upload anyway).
    cat > /opt/vaultwarden/backup-to-oci.sh << 'BACKUP'
    #!/bin/bash
    set -euo pipefail
    DATE=$(date +%Y-%m-%d-%H%M)
    BACKUP_FILE="/tmp/vault-backup-$DATE.tar.gz"
    trap 'rm -f "$BACKUP_FILE"' EXIT

    tar -czf "$BACKUP_FILE" -C /opt/vaultwarden data
    rclone copy "$BACKUP_FILE" oci_backup:vault-backups/
    echo "[$(date)] OCI backup complete: $DATE"
    BACKUP
    chmod +x /opt/vaultwarden/backup-to-oci.sh

    # ── Cron jobs (as ubuntu; log files were pre-created and chowned above) ─
    (crontab -u ubuntu -l 2>/dev/null || true; cat << 'CRON'
    # Restore newest AWS snapshot nightly at 01:00 UTC (STANDBY MODE only)
    0 1 * * * /opt/vaultwarden/sync-from-aws.sh >> /var/log/vault-sync.log 2>&1

    # Backup to OCI Object Storage nightly at 02:00 UTC (always runs)
    0 2 * * * /opt/vaultwarden/backup-to-oci.sh >> /var/log/vault-backup-oci.log 2>&1
    CRON
    ) | crontab -u ubuntu -

    systemctl enable fail2ban && systemctl start fail2ban

    echo "Micro B bootstrap complete."
    echo "Next step: as ubuntu, run 'rclone config' to set up aws_vault and oci_backup"
  EOF
}
