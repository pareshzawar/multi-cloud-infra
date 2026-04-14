###############################################################################
# environments/prod/main.tf
# Root module — wires all sub-modules together for Plan B multi-cloud stack
###############################################################################

terraform {
  required_version = ">= 1.7.0"

  required_providers {
    oci = {
      source  = "oracle/oci"
      version = "~> 6.0"
    }
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    google = {
      source  = "hashicorp/google"
      version = "~> 5.0"
    }
    azuread = {
      source  = "hashicorp/azuread"
      version = "~> 2.47"
    }
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 4.0"
    }
  }

  # Remote state in OCI Object Storage (free tier — 10 GB always free)
  # Uncomment after first apply creates the bucket, then migrate state
  # backend "s3" {
  #   bucket                      = "terraform-state-YOUR_TENANCY"
  #   key                         = "prod/terraform.tfstate"
  #   region                      = "us-phoenix-1"
  #   endpoint                    = "https://YOUR_NAMESPACE.compat.objectstorage.us-phoenix-1.oraclecloud.com"
  #   shared_credentials_file     = "~/.aws/credentials"
  #   skip_credentials_validation = true
  #   skip_metadata_api_check     = true
  #   skip_region_validation      = true
  #   force_path_style            = true
  # }

    # Remote state in OCI Object Storage (free tier — 10 GB always free)
  # Uncomment after first apply creates the bucket, then migrate state
  backend "s3" {
  bucket                      = "terraform-state-multicloud"
  key                         = "prod/terraform.tfstate"
  region                      = "us-ashburn-1"
  endpoint                    = "https://idkl5fdwo72e.compat.objectstorage.us-ashburn-1.oraclecloud.com"
  shared_credentials_file     = "~/.aws/credentials"
  skip_credentials_validation = true
  skip_metadata_api_check     = true
  skip_region_validation      = true
  force_path_style            = true
   }
}

###############################################################################
# Provider Configuration
###############################################################################

provider "oci" {
  tenancy_ocid = var.oci_tenancy_ocid
  user_ocid    = var.oci_user_ocid
  fingerprint  = var.oci_fingerprint
  private_key  = file("~/.oci/oci_api_key.pem")
  region       = var.oci_region
  config_file_profile = "DEFAULT"
}

provider "aws" {
  region = var.aws_region
}

provider "google" {
  project = var.gcp_project_id
  region  = var.gcp_region
  billing_project       = "cloudexplorersclub"
  user_project_override = true
}

provider "azuread" {
  tenant_id     = var.azure_tenant_id
  client_id     = var.azure_client_id
  client_secret = var.azure_client_secret
}

provider "cloudflare" {
  api_token = var.cloudflare_api_token
}

###############################################################################
# Module: OCI Networking
# VCN · Public Subnet (LB) · Private Subnet (Compute) · Gateways
###############################################################################

module "oci_networking" {
  source = "../../modules/oci-networking"

  compartment_id = var.oci_compartment_id
  region         = var.oci_region

  vcn_cidr            = "10.0.0.0/16"
  public_subnet_cidr  = "10.0.1.0/24" # Load Balancer lives here
  private_subnet_cidr = "10.0.2.0/24" # Ampere A1 lives here

  tags = local.common_tags
}

###############################################################################
# Module: OCI Security (NSGs + Security Lists)
# Fine-grained network security group rules per service
###############################################################################

module "oci_security" {
  source = "../../modules/oci-security"

  compartment_id    = var.oci_compartment_id
  vcn_id            = module.oci_networking.vcn_id
  public_subnet_id  = module.oci_networking.public_subnet_id
  private_subnet_id = module.oci_networking.private_subnet_id

  # Allowed source IPs for admin interfaces (tighten in production)
  # Use your home/office IP here for extra security, or keep 0.0.0.0/0
  # for LB-fronted public services
  admin_allowed_cidrs = var.admin_allowed_cidrs

  tags = local.common_tags
}

###############################################################################
# Module: OCI Load Balancer
# Always-Free Flexible LB (10 Mbps) · HTTP→HTTPS redirect · SSL termination
###############################################################################

module "oci_lb" {
  source = "../../modules/oci-lb"

  compartment_id   = var.oci_compartment_id
  public_subnet_id = module.oci_networking.public_subnet_id
  lb_nsg_id        = module.oci_security.lb_nsg_id

  # Backend = Ampere A1 private IP
  backend_instance_ip = module.oci_compute.private_ip
  backend_http_port   = 80 # Caddy listens on 80 inside VM
  backend_https_port  = 443

  domain_name   = var.domain_name
  n8n_subdomain = "n8n.${var.domain_name}"
  wg_subdomain  = "wg.${var.domain_name}"

  tags = local.common_tags
}

###############################################################################
# Module: OCI Compute
# Ampere A1 (4 OCPU / 24 GB) in private subnet
# cloud-init installs Docker, Caddy, Tailscale, all services
###############################################################################

module "oci_compute" {
  source = "../../modules/oci-compute"

  compartment_id      = var.oci_compartment_id
  availability_domain = var.oci_availability_domain
  private_subnet_id   = module.oci_networking.private_subnet_id
  compute_nsg_id      = module.oci_security.compute_nsg_id

  ssh_public_key = var.ssh_public_key

  # Passed into cloud-init for service configuration
  domain_name        = var.domain_name
  n8n_subdomain      = "n8n.${var.domain_name}"
  wg_subdomain       = "wg.${var.domain_name}"
  azure_tenant_id    = var.azure_tenant_id
  n8n_oidc_client_id = module.azure_sso.n8n_client_id
  n8n_oidc_secret    = module.azure_sso.n8n_client_secret
  tailscale_auth_key = var.tailscale_auth_key
  wireguard_host_ip  = module.oci_lb.public_ip # WG clients connect to LB IP

  tags = local.common_tags
}

###############################################################################
# Module: OCI Budget Alert
# Always-Free OCI resources should cost $0, but alert if any charges appear
###############################################################################

module "oci_budget" {
  source = "../../modules/oci-budget"

  tenancy_id    = var.oci_tenancy_ocid
  alert_email   = var.alert_email
  threshold_usd = 1.00

  tags = local.common_tags
}

###############################################################################
# Module: OCI Micro #2 — Ops & Monitoring Node
# AMD E2.1.Micro (always-free) — same VCN private subnet as Ampere A1
# Services: Uptime Kuma · Portainer CE · Watchtower · Fail2ban
# All admin UIs locked to Tailscale — no public ports
###############################################################################

module "oci_micro2" {
  source = "../../modules/oci-micro2"

  compartment_id      = var.oci_compartment_id
  availability_domain = var.oci_availability_domain # Same AD as A1 preferred
  private_subnet_id   = module.oci_networking.private_subnet_id
  micro2_nsg_id       = module.oci_security.micro2_nsg_id

  ssh_public_key     = var.ssh_public_key
  tailscale_auth_key = var.tailscale_auth_key
  domain_name        = var.domain_name
  alert_email        = var.alert_email

  # Pass A1 private IP so Portainer can auto-configure the agent endpoint
  a1_private_ip = module.oci_compute.private_ip

  tags = local.common_tags
}

###############################################################################
# Module: AWS Vault
# VPC · Private Subnet · EC2 t2/t3.micro · Vaultwarden · S3 backup bucket
###############################################################################

module "aws_vault" {
  source = "../../modules/aws-vault"

  aws_region     = var.aws_region
  ssh_public_key = var.ssh_public_key

  vpc_cidr            = "172.16.0.0/16"
  private_subnet_cidr = "172.16.1.0/24"
  public_subnet_cidr  = "172.16.2.0/24" # NAT GW needs a public subnet

  domain_name        = var.domain_name
  tailscale_auth_key = var.tailscale_auth_key

  # Vaultwarden S3 backup
  backup_bucket_name = "vaultwarden-backup-${var.aws_account_id}"

  tags = local.common_tags
}

###############################################################################
# Module: AWS Budget Alert
###############################################################################

module "aws_budget" {
  source = "../../modules/aws-budget"

  account_id    = var.aws_account_id
  alert_email   = var.alert_email
  threshold_usd = 1.00
}

###############################################################################
# Module: GCP Gateway
# VPC · e2-micro · Firewall rules · Nginx Proxy Manager · Uptime Kuma
###############################################################################

module "gcp_gateway" {
  source = "../../modules/gcp-gateway"

  project_id = var.gcp_project_id
  region     = var.gcp_region
  zone       = var.gcp_zone

  vpc_cidr           = "192.168.1.0/24"
  ssh_public_key     = var.ssh_public_key
  tailscale_auth_key = var.tailscale_auth_key

  # Routes to OCI backend via Tailscale
  oci_tailscale_ip = var.oci_tailscale_ip # set after first deploy

  domain_name           = var.domain_name
  uptime_kuma_subdomain = "status.${var.domain_name}"

  tags = local.common_tags
}

###############################################################################
# Module: GCP Budget Alert
###############################################################################

module "gcp_budget" {
  source             = "../../modules/gcp-budget"
  billing_account_id = var.gcp_billing_account_id
  project_id         = var.gcp_project_id
  alert_email        = var.alert_email
  threshold_usd      = 1.00
}

###############################################################################
# Module: Azure Entra ID SSO
# App registrations for OIDC — protects n8n, Uptime Kuma, WireGuard UI
###############################################################################

module "azure_sso" {
  source = "../../modules/azure-sso"

  tenant_id   = var.azure_tenant_id
  domain_name = var.domain_name

  # Redirect URIs for each protected app
  n8n_redirect_uri         = "https://n8n.${var.domain_name}/rest/oauth2-credential/callback"
  uptime_kuma_redirect_uri = "https://status.${var.domain_name}/auth/callback"
  wg_redirect_uri          = "https://wg.${var.domain_name}/auth/callback"
}

###############################################################################
# Cloudflare DNS Records
###############################################################################

# Root domain → GCP public IP (proxied through Cloudflare)
resource "cloudflare_record" "root" {
  zone_id         = var.cloudflare_zone_id
  name            = "@"
  value           = module.gcp_gateway.public_ip
  type            = "A"
  proxied         = true
  allow_overwrite = true # overwrite if record already exists in Cloudflare

  lifecycle {
    ignore_changes = [value] # prevent flapping if IP changes mid-apply
  }
}

resource "cloudflare_record" "www" {
  zone_id         = var.cloudflare_zone_id
  name            = "www"
  content           = module.gcp_gateway.public_ip
  type            = "A"
  proxied         = true
  allow_overwrite = true
}

resource "cloudflare_record" "n8n" {
  zone_id         = var.cloudflare_zone_id
  name            = "n8n"
  value           = module.gcp_gateway.public_ip
  type            = "A"
  proxied         = true
  allow_overwrite = true
}

resource "cloudflare_record" "status" {
  zone_id         = var.cloudflare_zone_id
  name            = "status"
  value           = module.gcp_gateway.public_ip
  type            = "A"
  proxied         = true
  allow_overwrite = true
}

# Vault — DNS only (no Cloudflare proxy — Tailscale access only)
resource "cloudflare_record" "vault" {
  zone_id         = var.cloudflare_zone_id
  name            = "vault"
  content         = module.aws_vault.tailscale_ip
  type            = "A"
  proxied         = false # DNS only — not publicly routable
  allow_overwrite = true
}

# WireGuard — points to OCI Load Balancer public IP
resource "cloudflare_record" "wg" {
  zone_id         = var.cloudflare_zone_id
  name            = "wg"
  value           = module.oci_lb.public_ip
  type            = "A"
  proxied         = false # Direct to OCI LB for UDP WireGuard
  allow_overwrite = true
}

# Cloudflare SSL/TLS settings
resource "cloudflare_zone_settings_override" "ssl" {
  zone_id = var.cloudflare_zone_id

  settings {
    ssl                      = "strict"
    always_use_https         = "on"
    min_tls_version          = "1.2"
    automatic_https_rewrites = "on"
    security_level           = "medium"
    # Note: image_resizing, cache_level are read-only on Free plan — omitted
  }
}

###############################################################################
# Local values
###############################################################################

locals {
  common_tags = {
    project     = "multi-cloud-infra"
    environment = "prod"
    managed_by  = "terraform"
    repo        = "github.com/${var.github_org}/${var.github_repo}"
  }
}

###############################################################################
# OCI Tenancy 2 — Second OCI account (different email)
# Provisions 2x E2.1.Micro Always Free instances:
#   micro_a — overflow worker (Docker, Tailscale)
#   micro_b — Vaultwarden STANDBY + webhook relay + rclone backup aggregator
#
# SETUP: Uncomment the provider and module blocks below once you have a
# second OCI account and have generated an API key for it.
# See MANUAL_SETUP.md section 5 for step-by-step instructions.
###############################################################################

# provider "oci" {
#   alias        = "tenancy2"
#   tenancy_ocid = var.oci2_tenancy_ocid
#   user_ocid    = var.oci2_user_ocid
#   fingerprint  = var.oci2_fingerprint
#   private_key  = file("~/.oci/oci_api_key_2.pem")
#   region       = var.oci2_region
# }

# module "oci2_compute" {
#   source    = "../../modules/oci-compute2"
#   providers = { oci = oci.tenancy2 }
#
#   compartment_id      = var.oci2_tenancy_ocid
#   availability_domain = var.oci2_availability_domain
#   ssh_public_key      = var.ssh_public_key
#   tailscale_auth_key  = var.tailscale_auth_key
#   domain_name         = var.domain_name
#   n8n_tailscale_ip    = var.oci_tailscale_ip   # OCI A1 Tailscale IP for webhook relay
#
#   tags = local.common_tags
# }
provider "oci" {
  alias        = "tenancy2"
  tenancy_ocid = var.oci2_tenancy_ocid
  user_ocid    = var.oci2_user_ocid
  fingerprint  = var.oci2_fingerprint
  private_key  = file("~/.oci/oci_api_key.pem")
  region       = var.oci2_region
  config_file_profile = "PARESH"

}

module "oci2_compute" {
  source    = "../../modules/oci-compute2"
  providers = { oci = oci.tenancy2 }

  compartment_id      = var.oci2_tenancy_ocid
  availability_domain = var.oci2_availability_domain
  ssh_public_key      = var.ssh_public_key
  tailscale_auth_key  = var.tailscale_auth_key

  tags = local.common_tags
}