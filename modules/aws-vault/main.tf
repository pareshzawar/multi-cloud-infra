###############################################################################
# modules/aws-vault/main.tf
# The Vault — isolated AWS account for Vaultwarden
#
# NAT REMOVAL — ROUTE-FLIP APPROACH (instance is NEVER replaced):
#   · Instance stays in its existing subnet (subnet-0ed3906bbcff7788d).
#   · That subnet's route table default route is flipped NAT -> IGW.
#   · An Elastic IP is associated to the RUNNING instance (in-place) so it
#     has a public IP for outbound via the IGW. Vaultwarden is NOT exposed.
#   · NAT Gateway + its EIP are removed (the ~$44/month saving).
#   · S3 SSE changed aws:kms -> AES256 (free).
#
# CRITICAL — every value below matches live state to avoid replacement:
#   subnet_id, associate_public_ip_address=false, key_name, SG name/description.
#   Do NOT "tidy" the subnet name, SG description, or IGW resource name —
#   each is ForceNew and would destroy the vault.
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
# Resource name MUST stay "igw" to match state (igw-02ae33e6cbd85ac84).

resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.vault.id
  tags   = merge(var.tags, { Name = "vault-igw" })
}

# ── Subnets ───────────────────────────────────────────────────────────────────
# CIDRs/AZ hardcoded to match the live subnets exactly. The instance lives in
# aws_subnet.private; after the route flip that subnet reaches the internet via
# the IGW. (Name kept as "private" to match state — rename later via a moved
# block, never by editing here.)

resource "aws_subnet" "private" {
  vpc_id            = aws_vpc.vault.id
  cidr_block        = "172.16.1.0/24" # subnet-0ed3906bbcff7788d — DO NOT CHANGE (instance lives here)
  availability_zone = "ap-south-1a"

  tags = merge(var.tags, { Name = "vault-private-subnet" })
}

resource "aws_subnet" "public" {
  vpc_id            = aws_vpc.vault.id
  cidr_block        = "172.16.2.0/24" # subnet-01a4ad662701b0060 — kept; empty after NAT removal
  availability_zone = "ap-south-1a"

  tags = merge(var.tags, { Name = "vault-public-subnet" })
}

# ── Route Tables ──────────────────────────────────────────────────────────────

# Instance's route table — THE FLIP: default route now via IGW (was NAT GW).
resource "aws_route_table" "private" {
  vpc_id = aws_vpc.vault.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id # was: nat_gateway_id = aws_nat_gateway.nat.id
  }

  tags = merge(var.tags, { Name = "vault-private-rt" })
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.vault.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }

  tags = merge(var.tags, { Name = "vault-public-rt" })
}

resource "aws_route_table_association" "private" {
  subnet_id      = aws_subnet.private.id
  route_table_id = aws_route_table.private.id
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

# ── Elastic IP for the running instance (replaces NAT egress) ──────────────────
# Associated to the existing instance/ENI — in-place, NO replacement.

resource "aws_eip" "vault" {
  domain = "vpc"
  tags   = merge(var.tags, { Name = "vault-eip" })
}

resource "aws_eip_association" "vault" {
  instance_id   = aws_instance.vault.id
  allocation_id = aws_eip.vault.id
}

# ── Security Group ────────────────────────────────────────────────────────────
# name + description + ingress MUST match state — description is ForceNew, and a
# new public IP makes any 0.0.0.0/0 service port a real exposure. SSH stays
# scoped to the Tailscale CGNAT range.

resource "aws_security_group" "vault" {
  name        = "vault-sg"
  description = "Vaultwarden - Tailscale only, no public Vaultwarden port"
  vpc_id      = aws_vpc.vault.id

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["100.64.0.0/10"]
    description = "SSH via Tailscale"
  }

  ingress {
    from_port   = 41641
    to_port     = 41641
    protocol    = "udp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "Tailscale UDP"
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.tags, { Name = "vault-security-group" })
}

# ── SSH key pair (restored — its absence was forcing an SSH lockout) ───────────

resource "aws_key_pair" "vault" {
  key_name   = "vault-key"
  public_key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIA5N9dM0U7h4X4tyUBYd+IhWfpvyHLT2Ul8vGJPoNTJl multi-cloud-infra"
  tags       = var.tags
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
      sse_algorithm = "AES256" # was aws:kms ($1/month)
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
# UNCHANGED placement: stays in aws_subnet.private, public IP via EIP (above),
# associate_public_ip_address=false. key_name restored. All ForceNew attributes
# match state, so this plans as in-place (tags only) — never replaced.

resource "aws_instance" "vault" {
  ami                         = data.aws_ami.ubuntu_22.id
  instance_type               = var.instance_type
  subnet_id                   = aws_subnet.private.id
  vpc_security_group_ids      = [aws_security_group.vault.id]
  iam_instance_profile        = aws_iam_instance_profile.vault_ec2.name
  key_name                    = aws_key_pair.vault.key_name
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
