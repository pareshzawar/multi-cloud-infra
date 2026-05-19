###############################################################################
# modules/aws-vault/main.tf
# The Vault — isolated AWS account for Vaultwarden
#
# CHANGES IN THIS PR (feat/remove-nat-gateway):
#   REMOVED  aws_nat_gateway          — was ~$40.32/month in ap-south-1
#   REMOVED  aws_eip                  — was $3.60/month
#   REMOVED  aws_subnet.private       — no longer needed
#   REMOVED  aws_route_table.private  — no longer needed
#   CHANGED  aws_instance subnet_id   → aws_subnet.public
#   CHANGED  associate_public_ip_address = true (outbound internet direct via IGW)
#   CHANGED  sse_algorithm AES256     — was aws:kms ($1/month KMS key charge)
#
# SECURITY POSTURE: UNCHANGED
#   Vaultwarden still binds to Tailscale IP only (ROCKET_ADDRESS=$TS_IP)
#   Security group still has ZERO public port rules for :8080
#   UFW still has no :8080 rule
#   Public IP on EC2 = outbound internet only. Nothing listens on it publicly.
#   Access path: Tailscale → :8080 — exactly as before
#
# MONTHLY SAVING: ~$45/month (NAT GW $40.32 + EIP $3.60 + KMS $1.00)
###############################################################################

data "aws_ami" "ubuntu_22" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# ── VPC ───────────────────────────────────────────────────────────────────────

resource "aws_vpc" "vault" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = merge(var.tags, { Name = "vault-vpc" })
}

# ── Subnet ────────────────────────────────────────────────────────────────────
# Single public subnet. EC2 gets a public IP for outbound internet access.
# Vaultwarden does NOT listen on the public IP — it binds to Tailscale IP only.
# REMOVED: aws_subnet.private (172.16.1.0/24) — only existed for NAT GW routing.

resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.vault.id
  cidr_block              = var.public_subnet_cidr
  availability_zone       = "${var.aws_region}a"
  map_public_ip_on_launch = false # Controlled explicitly on the instance

  tags = merge(var.tags, { Name = "vault-public-subnet" })
}

# ── Internet Gateway ──────────────────────────────────────────────────────────

resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.vault.id
  tags   = merge(var.tags, { Name = "vault-igw" })
}

# REMOVED: aws_eip.nat
# REMOVED: aws_nat_gateway.nat

# ── Route Table ───────────────────────────────────────────────────────────────
# Single route table — default route directly to IGW.
# REMOVED: aws_route_table.private + aws_route_table_association.private

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.vault.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }

  tags = merge(var.tags, { Name = "vault-public-rt" })
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

# ── Security Group ────────────────────────────────────────────────────────────
# UNCHANGED — zero public ports for Vaultwarden.
# Having a public IP on EC2 does not make Vaultwarden accessible publicly.
# Nothing is listening on the public IP from a security group perspective.

resource "aws_security_group" "vault" {
  name        = "vault-sg"
  description = "Vaultwarden - Tailscale only, zero public Vaultwarden port"
  vpc_id      = aws_vpc.vault.id

  # Tailscale UDP — required for mesh formation
  ingress {
    description = "Tailscale UDP"
    from_port   = 41641
    to_port     = 41641
    protocol    = "udp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # SSH — Tailscale CGNAT range only (100.64.0.0/10)
  ingress {
    description = "SSH via Tailscale only"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["100.64.0.0/10"]
  }

  # NOTE: No :8080 rule — Vaultwarden has zero public exposure

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.tags, { Name = "vault-security-group" })
}

# ── SSH Key Pair ──────────────────────────────────────────────────────────────

resource "aws_key_pair" "vault" {
  key_name   = "vault-key"
  public_key = var.ssh_public_key
  tags       = var.tags
}

# ── EC2: Vaultwarden ──────────────────────────────────────────────────────────
# CHANGED: subnet_id       = aws_subnet.public.id   (was aws_subnet.private.id)
# CHANGED: associate_public_ip_address = true        (was false — relied on NAT GW)
# UNCHANGED: Vaultwarden binds to Tailscale IP only inside the instance.

resource "aws_instance" "vault" {
  ami                    = data.aws_ami.ubuntu_22.id
  instance_type          = "t3.micro"
  subnet_id              = aws_subnet.public.id                 # CHANGED
  vpc_security_group_ids = [aws_security_group.vault.id]
  key_name               = aws_key_pair.vault.key_name
  iam_instance_profile   = aws_iam_instance_profile.vault_ec2.name

  associate_public_ip_address = true                            # CHANGED

  root_block_device {
    volume_type           = "gp3"
    volume_size           = 20
    delete_on_termination = true
    encrypted             = true
  }

  user_data = base64encode(local.vault_cloud_init)

  tags = merge(var.tags, { Name = "vault-vaultwarden" })

  lifecycle {
    prevent_destroy = true
    ignore_changes  = [ami, associate_public_ip_address]
  }
}

locals {
  vault_cloud_init = <<-EOF
    #!/bin/bash
    set -euo pipefail

    # ── System update ──────────────────────────────────────────────────────
    apt-get update && apt-get upgrade -y
    apt-get install -y curl wget git ufw fail2ban unattended-upgrades

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
    tailscale up --authkey=${var.tailscale_auth_key} --hostname=aws-vault --accept-routes
    systemctl enable tailscaled

    # ── Wait for Tailscale IP ─────────────────────────────────────────────
    sleep 10
    TS_IP=$(tailscale ip -4)
    echo "Tailscale IP: $TS_IP"

    # ── Vaultwarden ───────────────────────────────────────────────────────
    mkdir -p /opt/vaultwarden/data
    chown -R ubuntu:ubuntu /opt/vaultwarden

    cat > /opt/vaultwarden/docker-compose.yml << COMPOSE
    version: '3.8'
    services:
      vaultwarden:
        image: vaultwarden/server:latest
        container_name: vaultwarden
        restart: unless-stopped
        environment:
          ROCKET_ADDRESS: "$${TS_IP}"
          ROCKET_PORT: "8080"
          DOMAIN: "https://vault.${var.domain_name}"
          SIGNUPS_ALLOWED: "false"
          WEBSOCKET_ENABLED: "true"
          LOG_LEVEL: "warn"
        volumes:
          - ./data:/data
        ports:
          - "$${TS_IP}:8080:80"
          - "$${TS_IP}:3012:3012"
    COMPOSE

    cd /opt/vaultwarden && docker compose up -d

    # ── S3 backup cron ────────────────────────────────────────────────────
    cat > /opt/vaultwarden/backup.sh << 'BACKUP'
    #!/bin/bash
    set -euo pipefail
    DATE=$(date +%Y-%m-%d-%H%M)
    BACKUP_FILE="/tmp/vault-backup-$DATE.tar.gz"
    tar -czf "$BACKUP_FILE" /opt/vaultwarden/data/
    aws s3 cp "$BACKUP_FILE" "s3://${var.backup_bucket_name}/vault-backup-$DATE.tar.gz" \
      --server-side-encryption AES256
    rm -f "$BACKUP_FILE"
    echo "Backup complete: $DATE" >> /var/log/vault-backup.log
    BACKUP
    chmod +x /opt/vaultwarden/backup.sh
    (crontab -l 2>/dev/null; echo "0 2 * * * /opt/vaultwarden/backup.sh >> /var/log/vault-backup.log 2>&1") | crontab -

    # ── UFW ───────────────────────────────────────────────────────────────
    ufw default deny incoming
    ufw default allow outgoing
    ufw allow 41641/udp comment "Tailscale"
    # No :8080 — Vaultwarden is Tailscale-only. Public IP has nothing listening.
    ufw --force enable

    systemctl enable fail2ban && systemctl start fail2ban
    echo "Vault bootstrap complete"
  EOF
}

# ── S3 Backup Bucket ──────────────────────────────────────────────────────────

resource "aws_s3_bucket" "backup" {
  bucket        = var.backup_bucket_name
  force_destroy = false
  tags          = merge(var.tags, { Name = "vault-backup-bucket" })
}

resource "aws_s3_bucket_versioning" "backup" {
  bucket = aws_s3_bucket.backup.id
  versioning_configuration {
    status = "Enabled"
  }
}

# CHANGED: sse_algorithm = "AES256" (was "aws:kms")
# AES256 = free S3-managed encryption. aws:kms = $1/month KMS key charge.
# For a personal backup bucket, AES256 is equally secure.
resource "aws_s3_bucket_server_side_encryption_configuration" "backup" {
  bucket = aws_s3_bucket.backup.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"               # CHANGED — saves $1/month
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "backup" {
  bucket = aws_s3_bucket.backup.id

  rule {
    id     = "expire-old-backups"
    status = "Enabled"

    expiration {
      days = 30
    }

    noncurrent_version_expiration {
      noncurrent_days = 7
    }
  }
}

resource "aws_s3_bucket_public_access_block" "backup" {
  bucket                  = aws_s3_bucket.backup.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# ── IAM Role for EC2 → S3 ────────────────────────────────────────────────────

resource "aws_iam_role" "vault_ec2" {
  name = "vault-ec2-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })

  tags = var.tags
}

resource "aws_iam_role_policy" "vault_s3" {
  name = "vault-s3-backup-policy"
  role = aws_iam_role.vault_ec2.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "s3:PutObject",
        "s3:GetObject",
        "s3:DeleteObject",
        "s3:ListBucket"
      ]
      Resource = [
        aws_s3_bucket.backup.arn,
        "${aws_s3_bucket.backup.arn}/*"
      ]
    }]
  })
}

resource "aws_iam_instance_profile" "vault_ec2" {
  name = "vault-ec2-profile"
  role = aws_iam_role.vault_ec2.name
  tags = var.tags
}
