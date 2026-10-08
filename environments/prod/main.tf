###############################################################################
# environments/prod/main.tf
# Root module — wires all sub-modules together for Plan B multi-cloud stack
###############################################################################

terraform {
  required_version = ">= 1.7.5"

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

  # Backend configuration is in backend.tf
}

###############################################################################
# Provider Configuration
###############################################################################

# FIX 5: Removed "config_file_profile" — CI runners have no ~/.oci/config file.
#         Credentials come from TF_VAR_* env vars injected by GitHub Actions.
# FIX 6: Replaced file("~/.oci/oci_api_key.pem") with var.oci_private_key —
#         ~/.oci/ does not exist on GitHub Actions runners.
provider "oci" {
  tenancy_ocid = var.oci_tenancy_ocid
  user_ocid    = var.oci_user_ocid
  fingerprint  = var.oci_fingerprint
  private_key  = var.oci_private_key
  region       = var.oci_region
}

provider "aws" {
  region = var.aws_region
  # Prevents AWS provider from calling STS during init with wrong credentials
  skip_requesting_account_id = true
}

provider "google" {
  project               = var.gcp_project_id
  region                = var.gcp_region
  billing_project       = var.gcp_project_id # FIX 7: was hardcoded "cloudexplorersclub"
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

# FIX 8: Tenancy 2 provider — same as above: removed config_file_profile and
#         file() reference. Uses var.oci2_private_key from env vars instead.
provider "oci" {
  alias        = "tenancy2"
  tenancy_ocid = var.oci2_tenancy_ocid
  user_ocid    = var.oci2_user_ocid
  fingerprint  = var.oci2_fingerprint
  private_key  = var.oci2_private_key
  region       = var.oci2_region
}

###############################################################################
# Module: OCI Networking
###############################################################################

module "oci_networking" {
  source = "../../modules/oci-networking"

  compartment_id = var.oci_compartment_id
  region         = var.oci_region

  vcn_cidr            = "10.0.0.0/16"
  public_subnet_cidr  = "10.0.1.0/24"
  private_subnet_cidr = "10.0.2.0/24"

  tags = local.common_tags
}

###############################################################################
# Module: OCI Security
###############################################################################

module "oci_security" {
  source = "../../modules/oci-security"

  compartment_id      = var.oci_compartment_id
  vcn_id              = module.oci_networking.vcn_id
  public_subnet_id    = module.oci_networking.public_subnet_id
  private_subnet_id   = module.oci_networking.private_subnet_id
  public_subnet_cidr  = "10.0.1.0/24" # keep in sync with module.oci_networking
  admin_allowed_cidrs = var.admin_allowed_cidrs

  tags = local.common_tags
}

# The security lists moved from oci-security to oci-networking (so the subnets
# can attach them). These blocks tell Terraform it is the same object, so an
# existing deployment updates in place instead of destroy + recreate.
moved {
  from = module.oci_security.oci_core_security_list.public
  to   = module.oci_networking.oci_core_security_list.public
}

moved {
  from = module.oci_security.oci_core_security_list.private
  to   = module.oci_networking.oci_core_security_list.private
}

###############################################################################
# Module: OCI Load Balancer
###############################################################################

module "oci_lb" {
  source = "../../modules/oci-lb"

  compartment_id   = var.oci_compartment_id
  public_subnet_id = module.oci_networking.public_subnet_id
  lb_nsg_id        = module.oci_security.lb_nsg_id

  backend_instance_ip = module.oci_compute.private_ip
  backend_http_port   = 80
  backend_https_port  = 443

  domain_name   = var.domain_name
  n8n_subdomain = "n8n.${var.domain_name}"
  wg_subdomain  = "wg.${var.domain_name}"

  tags = local.common_tags
}

###############################################################################
# Module: OCI Compute — Ampere A1
###############################################################################

module "oci_compute" {
  source = "../../modules/oci-compute"

  compartment_id      = var.oci_compartment_id
  availability_domain = var.oci_availability_domain
  private_subnet_id   = module.oci_networking.private_subnet_id
  compute_nsg_id      = module.oci_security.compute_nsg_id

  ssh_public_key = var.ssh_public_key

  domain_name        = var.domain_name
  n8n_subdomain      = "n8n.${var.domain_name}"
  wg_subdomain       = "wg.${var.domain_name}"
  tailscale_auth_key = var.tailscale_auth_key
  # WireGuard is UDP, which only the Network Load Balancer listens for —
  # the flexible LB IP (module.oci_lb.public_ip) has no UDP listener.
  wireguard_host_ip = module.oci_lb.wg_nlb_public_ip

  tags = local.common_tags
}

###############################################################################
# Module: OCI Budget
###############################################################################

module "oci_budget" {
  source = "../../modules/oci-budget"

  tenancy_id    = var.oci_tenancy_ocid
  alert_email   = var.alert_email
  threshold_usd = 1.00

  tags = local.common_tags
}

###############################################################################
# Module: OCI Micro #2 — Ops Node
###############################################################################

module "oci_micro2" {
  source = "../../modules/oci-micro2"

  compartment_id      = var.oci_compartment_id
  availability_domain = var.oci_availability_domain
  private_subnet_id   = module.oci_networking.private_subnet_id
  micro2_nsg_id       = module.oci_security.micro2_nsg_id
  ssh_public_key      = var.ssh_public_key

  tailscale_auth_key = var.tailscale_auth_key

  tags = local.common_tags
}

###############################################################################
# Module: OCI Tenancy 2 — Overflow Worker + Vault Standby
###############################################################################

module "oci2_compute" {
  source    = "../../modules/oci-compute2"
  providers = { oci = oci.tenancy2 }

  compartment_id      = var.oci2_compartment_id # was the tenancy OCID; this var was declared but unused
  availability_domain = var.oci2_availability_domain
  ssh_public_key      = var.ssh_public_key
  tailscale_auth_key  = var.tailscale_auth_key
  backup_bucket_name  = "vaultwarden-backup-${var.aws_account_id}" # same bucket aws_vault writes to

  tags = local.common_tags
}

###############################################################################
# Module: AWS Vault
# NAT Gateway removed: the instance stays in its original subnet (172.16.1.0/24),
# whose route table now points at the IGW; an Elastic IP gives it egress.
###############################################################################

module "aws_vault" {
  source = "../../modules/aws-vault"

  aws_region         = var.aws_region
  vpc_cidr           = "172.16.0.0/16"
  availability_zone  = var.aws_availability_zone
  instance_type      = "t3.micro"
  tailscale_auth_key = var.tailscale_auth_key
  tailscale_hostname = "aws-vault"
  backup_bucket_name = "vaultwarden-backup-${var.aws_account_id}"

  tags = local.common_tags
}

###############################################################################
# Module: AWS Budget
###############################################################################

module "aws_budget" {
  source = "../../modules/aws-budget"

  account_id    = var.aws_account_id # used to scope the SNS topic policy
  alert_email   = var.alert_email
  threshold_usd = 1.00
}

###############################################################################
# Module: GCP Gateway
###############################################################################

module "gcp_gateway" {
  source = "../../modules/gcp-gateway"

  project_id            = var.gcp_project_id
  region                = var.gcp_region
  zone                  = var.gcp_zone
  ssh_public_key        = var.ssh_public_key
  uptime_kuma_subdomain = var.uptime_kuma_subdomain

  vpc_cidr = "192.168.1.0/24"
  # Only Cloudflare may reach ports 80/443, so the proxy cannot be bypassed.
  cloudflare_ipv4_cidrs = data.cloudflare_ip_ranges.cloudflare.ipv4_cidr_blocks
  tailscale_auth_key    = var.tailscale_auth_key
  oci_tailscale_ip      = var.oci_tailscale_ip
  domain_name           = var.domain_name

  tags = local.common_tags
}

###############################################################################
# Module: GCP Budget
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
###############################################################################

module "azure_sso" {
  source = "../../modules/azure-sso"

  tenant_id   = var.azure_tenant_id
  domain_name = var.domain_name
  # Off by default: a personal Entra tenant usually lacks the permission to
  # create app registrations. See MANUAL_SETUP.md.
  create_apps = var.azure_sso_create_apps

  n8n_redirect_uri         = "https://n8n.${var.domain_name}/rest/oauth2-credential/callback"
  uptime_kuma_redirect_uri = "https://status.${var.domain_name}/auth/callback"
  wg_redirect_uri          = "https://wg.${var.domain_name}/auth/callback"
}

###############################################################################
# Cloudflare DNS Records
# FIX 10: Standardised all records to use "content" (replaces deprecated "value")
###############################################################################

resource "cloudflare_record" "root" {
  zone_id         = var.cloudflare_zone_id
  name            = "@"
  content         = module.gcp_gateway.public_ip
  type            = "A"
  proxied         = true
  allow_overwrite = true
}

resource "cloudflare_record" "www" {
  zone_id         = var.cloudflare_zone_id
  name            = "www"
  content         = module.gcp_gateway.public_ip
  type            = "A"
  proxied         = true
  allow_overwrite = true
}

resource "cloudflare_record" "n8n" {
  zone_id         = var.cloudflare_zone_id
  name            = "n8n"
  content         = module.gcp_gateway.public_ip
  type            = "A"
  proxied         = true
  allow_overwrite = true
}

resource "cloudflare_record" "status" {
  zone_id         = var.cloudflare_zone_id
  name            = "status"
  content         = module.gcp_gateway.public_ip
  type            = "A"
  proxied         = true
  allow_overwrite = true
}

# No public "vault" record: Vaultwarden is reached via its Tailscale MagicDNS
# name (https://aws-vault.<tailnet>.ts.net). Publishing a 100.x CGNAT address
# in public DNS only leaked the tailnet IP and could never get a valid cert.

resource "cloudflare_record" "wg" {
  zone_id         = var.cloudflare_zone_id
  name            = "wg"
  content         = module.oci_lb.public_ip # admin UI (HTTPS via Caddy). VPN clients dial the NLB IP directly (WG_HOST).
  type            = "A"
  proxied         = false
  allow_overwrite = true
}

# Cloudflare's published edge ranges — used to lock the GCP gateway firewall.
data "cloudflare_ip_ranges" "cloudflare" {}

resource "cloudflare_zone_settings_override" "ssl" {
  zone_id = var.cloudflare_zone_id

  settings {
    ssl                      = "strict"
    always_use_https         = "on"
    min_tls_version          = "1.2"
    automatic_https_rewrites = "on"
    security_level           = "medium"
  }
}

###############################################################################
# Locals
###############################################################################

locals {
  common_tags = {
    project     = "multi-cloud-infra"
    environment = "prod"
    managed_by  = "terraform"
    repo        = "github.com/${var.github_org}/${var.github_repo}"
  }
}
