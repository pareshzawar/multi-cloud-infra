###############################################################################
# modules/aws-vault/main.tf
# The Vault — isolated AWS account for Vaultwarden
# VPC · Private subnet · EC2 t2/t3.micro · No public port for Vaultwarden
# Vaultwarden bound to Tailscale IP only (zero public exposure)
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

# ── Subnets ───────────────────────────────────────────────────────────────────

# Public subnet — only for NAT Gateway (Vaultwarden has no public port)
resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.vault.id
  cidr_block              = var.public_subnet_cidr
  availability_zone       = "${var.aws_region}a"
  map_public_ip_on_launch = false # No public IPs

  tags = merge(var.tags, { Name = "vault-public-subnet" })
}

# Private subnet — Vaultwarden EC2 lives here
resource "aws_subnet" "private" {
  vpc_id            = aws_vpc.vault.id
  cidr_block        = var.private_subnet_cidr
  availability_zone = "${var.aws_region}a"

  tags = merge(var.tags, { Name = "vault-private-subnet" })
}

# ── Gateways ──────────────────────────────────────────────────────────────────

resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.vault.id
  tags   = merge(var.tags, { Name = "vault-igw" })
}

resource "aws_eip" "nat" {
  domain = "vpc"
  tags   = merge(var.tags, { Name = "vault-nat-eip" })
}

resource "aws_nat_gateway" "nat" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public.id # NAT GW must be in public subnet
  tags          = merge(var.tags, { Name = "vault-nat-gw" })

  depends_on = [aws_internet_gateway.igw]
}

# ── Route Tables ──────────────────────────────────────────────────────────────

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

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.vault.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.nat.id
  }

  tags = merge(var.tags, { Name = "vault-private-rt" })
}

resource "aws_route_table_association" "private" {
  subnet_id      = aws_subnet.private.id
  route_table_id = aws_route_table.private.id
}

# ── Security Group — Vault EC2 ────────────────────────────────────────────────
# NO port 8080 publicly. Only SSH (from Tailscale range) + Tailscale UDP.

resource "aws_security_group" "vault" {
  name        = "vault-sg"
  description = "Vaultwarden - Tailscale only, no public Vaultwarden port"
  vpc_id      = aws_vpc.vault.id

  # Tailscale control plane + UDP (allows mesh to form)
  ingress {
    description = "Tailscale UDP"
    from_port   = 41641
    to_port     = 41641
    protocol    = "udp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # SSH — locked to Tailscale CGNAT range only (100.64.0.0/10)
  # Once Tailscale is up, SSH only via Tailscale IP
  ingress {
    description = "SSH via Tailscale"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["100.64.0.0/10"] # Tailscale CGNAT range
  }

  # All outbound (for package updates, Tailscale, backups)
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

resource "aws_instance" "vault" {
  ami                    = data.aws_ami.ubuntu_22.id
  instance_type          = "t3.micro" # t3 preferred — t2 fallback for older regions
  subnet_id              = aws_subnet.private.id
  vpc_security_group_ids = [aws_security_group.vault.id]
  key_name               = aws_key_pair.vault.key_name

  # No public IP — private subnet
  associate_public_ip_address = false

  root_block_device {
    volume_type           = "gp3"
    volume_size           = 20 # GB — well within free tier 30 GB EBS
    delete_on_termination = true
    encrypted             = true # EBS encryption at rest
  }

  user_data = base64encode(local.vault_cloud_init)

  tags = merge(var.tags, { Name = "vault-vaultwarden" })

  lifecycle {
    prevent_destroy = true
    ignore_changes  = [ami] # Don't replace on AMI update
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

    # ── Vaultwarden via Docker ────────────────────────────────────────────
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
          ROCKET_ADDRESS: "$${TS_IP}"        # BIND ONLY TO TAILSCALE IP
          ROCKET_PORT: "8080"
          DOMAIN: "https://vault.${var.domain_name}"
          SIGNUPS_ALLOWED: "false"
          WEBSOCKET_ENABLED: "true"
          ADMIN_TOKEN: ""                    # Set: vaultwarden hash --preset owasp <password>
          LOG_LEVEL: "warn"
          EXTENDED_LOGGING: "true"
        volumes:
          - ./data:/data
        ports:
          - "$${TS_IP}:8080:80"              # ONLY Tailscale IP — not 0.0.0.0
          - "$${TS_IP}:3012:3012"            # WebSocket
    COMPOSE

    cd /opt/vaultwarden
    docker compose up -d

    # ── Backup script to S3 ───────────────────────────────────────────────
    cat > /opt/vaultwarden/backup.sh << 'BACKUP'
    #!/bin/bash
    set -euo pipefail
    DATE=$(date +%Y-%m-%d-%H%M)
    BUCKET="${var.backup_bucket_name}"
    BACKUP_FILE="/tmp/vault-backup-$DATE.tar.gz"
    tar -czf "$BACKUP_FILE" /opt/vaultwarden/data/
    # Encrypt before upload
    aws s3 cp "$BACKUP_FILE" "s3://$BUCKET/vault-backup-$DATE.tar.gz" \
      --server-side-encryption aws:kms
    rm -f "$BACKUP_FILE"
    echo "Backup complete: $DATE" >> /var/log/vault-backup.log
    BACKUP
    chmod +x /opt/vaultwarden/backup.sh

    # Schedule daily backup at 2 AM UTC
    (crontab -l 2>/dev/null; echo "0 2 * * * /opt/vaultwarden/backup.sh >> /var/log/vault-backup.log 2>&1") | crontab -

    # ── UFW firewall ──────────────────────────────────────────────────────
    ufw default deny incoming
    ufw default allow outgoing
    ufw allow 41641/udp comment "Tailscale"
    # No 8080 — Vaultwarden is Tailscale-only
    ufw --force enable

    # ── Fail2ban ──────────────────────────────────────────────────────────
    systemctl enable fail2ban && systemctl start fail2ban

    echo "Vault bootstrap complete"
  EOF
}

# ── S3 Backup Bucket ──────────────────────────────────────────────────────────

resource "aws_s3_bucket" "backup" {
  bucket        = var.backup_bucket_name
  force_destroy = false # Protect backups from accidental delete
  tags = merge(var.tags, { Name = "vault-backup-bucket" })
  
}

resource "aws_s3_bucket_versioning" "backup" {
  bucket = aws_s3_bucket.backup.id
  versioning_configuration {
    status = "Enabled" # Keep multiple versions for recovery
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "backup" {
  bucket = aws_s3_bucket.backup.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "aws:kms" # KMS encryption at rest
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "backup" {
  bucket = aws_s3_bucket.backup.id

  rule {
    id     = "expire-old-backups"
    status = "Enabled"

    expiration {
      days = 30 # Keep 30 days of backups — within S3 free tier (5 GB)
    }

    noncurrent_version_expiration {
      noncurrent_days = 7
    }
  }
}

# Block all public access to backup bucket
resource "aws_s3_bucket_public_access_block" "backup" {
  bucket = aws_s3_bucket.backup.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# ── IAM Role for EC2 to write to S3 ──────────────────────────────────────────

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
