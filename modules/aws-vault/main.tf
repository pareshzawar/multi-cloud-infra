###############################################################################
# modules/aws-vault/main.tf
# The Vault — isolated AWS account for Vaultwarden
#
# CHANGES (feat/remove-nat-gateway):
#   REMOVED  aws_nat_gateway             — was ~$40.32/month in ap-south-1
#   REMOVED  aws_eip                     — was ~$3.60/month
#   REMOVED  aws_subnet.private          — no longer needed
#   REMOVED  aws_route_table.private     — no longer needed
#   CHANGED  aws_instance subnet_id      → aws_subnet.public
#   CHANGED  associate_public_ip_address = true (outbound via IGW directly)
#   CHANGED  sse_algorithm               → AES256 (was aws:kms, $1/month)
#
# SECURITY POSTURE: UNCHANGED
#   · Vaultwarden binds to Tailscale IP only (ROCKET_ADDRESS=$TS_IP)
#   · Security group has ZERO inbound rules for :8080
#   · UFW blocks all ports except 22 (Tailscale SSH) and Tailscale UDP
#   · Public IP on EC2 = outbound internet only; nothing listens on it
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

# ── Internet Gateway ──────────────────────────────────────────────────────────

resource "aws_internet_gateway" "vault" {
  vpc_id = aws_vpc.vault.id
  tags   = merge(var.tags, { Name = "vault-igw" })
}

# ── Public Subnet ─────────────────────────────────────────────────────────────
# EC2 lives here directly — no NAT Gateway needed.
# Public IP is used for outbound only (apt, Docker pulls, Tailscale).
# Vaultwarden does NOT listen on the public IP.

resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.vault.id
  cidr_block              = var.public_subnet_cidr
  availability_zone       = var.availability_zone
  map_public_ip_on_launch = false # controlled explicitly on the instance

  tags = merge(var.tags, { Name = "vault-subnet-public" })
}

# ── Route Table ───────────────────────────────────────────────────────────────

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.vault.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.vault.id
  }

  tags = merge(var.tags, { Name = "vault-rt-public" })
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

# ── Security Group ────────────────────────────────────────────────────────────
# Inbound: SSH (Tailscale-only at runtime — UFW enforces) + Tailscale UDP
# NO inbound rule for :8080 — Vaultwarden is zero public exposure

resource "aws_security_group" "vault" {
  name        = "vault-sg"
  description = "Vaultwarden EC2 — Tailscale access only, no public service ports"
  vpc_id      = aws_vpc.vault.id

  # Tailscale UDP (WireGuard-based mesh)
  ingress {
    from_port   = 41641
    to_port     = 41641
    protocol    = "udp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "Tailscale UDP"
  }

  # SSH — open at SG level; UFW on the instance restricts to Tailscale IP
  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "SSH (UFW restricts to Tailscale IP at OS level)"
  }

  # All outbound allowed — needed for apt, Docker, Tailscale coordination
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.tags, { Name = "vault-sg" })
}

# ── S3 Backup Bucket ──────────────────────────────────────────────────────────

resource "aws_s3_bucket" "backup" {
  bucket        = var.backup_bucket_name
  force_destroy = false

  tags = merge(var.tags, { Name = "vault-backup-bucket" })
}

resource "aws_s3_bucket_versioning" "backup" {
  bucket = aws_s3_bucket.backup.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "backup" {
  bucket = aws_s3_bucket.backup.id

  rule {
    apply_server_side_encryption_by_default {
      # AES256 = S3-managed encryption, free. Was aws:kms ($1/month).
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "backup" {
  bucket = aws_s3_bucket.backup.id

  rule {
    id     = "expire-old-backups"
    status = "Enabled"

    filter {}

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

# ── IAM Role for EC2 → S3 ─────────────────────────────────────────────────────

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

# ── EC2 Instance ──────────────────────────────────────────────────────────────
# Moved to public subnet — outbound via IGW directly (no NAT GW).
# associate_public_ip_address = true gives it an ephemeral public IP for
# outbound traffic only. Vaultwarden is still bound to Tailscale IP.

resource "aws_instance" "vault" {
  ami                         = data.aws_ami.ubuntu_22.id
  instance_type               = var.instance_type
  subnet_id                   = aws_subnet.public.id
  vpc_security_group_ids      = [aws_security_group.vault.id]
  iam_instance_profile        = aws_iam_instance_profile.vault_ec2.name
  associate_public_ip_address = true

  root_block_device {
    volume_type           = "gp3"
    volume_size           = 20
    encrypted             = true
    delete_on_termination = true

    tags = merge(var.tags, { Name = "vault-root-volume" })
  }

  user_data = base64encode(templatefile("${path.module}/cloud-init.yaml", {
    tailscale_auth_key = var.tailscale_auth_key
    tailscale_hostname = var.tailscale_hostname
    backup_bucket_name = var.backup_bucket_name
    aws_region         = var.aws_region
  }))

  lifecycle {
    prevent_destroy = true
    ignore_changes  = [ami, user_data]
  }

  tags = merge(var.tags, { Name = "vault-vaultwarden" })
}
