###############################################################################
# environments/prod/variables.tf
###############################################################################

# ── OCI ──────────────────────────────────────────────────────────────────────

variable "oci_tenancy_ocid" {
  description = "OCI Tenancy OCID"
  type        = string
  sensitive   = true
}

variable "oci_user_ocid" {
  description = "OCI User OCID"
  type        = string
  sensitive   = true
}

variable "oci_fingerprint" {
  description = "OCI API key fingerprint"
  type        = string
  sensitive   = true
}

variable "oci_region" {
  description = "OCI home region (e.g. ap-mumbai-1 for India)"
  type        = string
  default     = "ap-mumbai-1"
}

variable "oci_compartment_id" {
  description = "OCI Compartment OCID (use tenancy OCID for root compartment)"
  type        = string
  sensitive   = true
}

variable "oci_availability_domain" {
  description = "OCI Availability Domain for Ampere A1 (e.g. VoXO:AP-MUMBAI-1-AD-1)"
  type        = string
}


#-------- Tenacy 2-------------------------

variable "oci2_tenancy_ocid" { type = string }
variable "oci2_user_ocid" { type = string }
variable "oci2_fingerprint" { type = string }
variable "oci2_region" { type = string }
variable "oci2_availability_domain" { type = string }
variable "oci2_compartment_id" { type = string }

# ── AWS ──────────────────────────────────────────────────────────────────────

variable "aws_region" {
  description = "AWS region (free tier available in all regions)"
  type        = string
  default     = "ap-south-1" # Mumbai — close to OCI Mumbai
}

variable "aws_account_id" {
  description = "AWS Account ID (12-digit number)"
  type        = string
  sensitive   = true
}
# ── GCP ──────────────────────────────────────────────────────────────────────

variable "gcp_project_id" {
  description = "GCP Project ID"
  type        = string
}

variable "gcp_billing_account_id" {
  description = "GCP Billing Account ID"
  type        = string
}

variable "gcp_region" {
  description = "GCP region — MUST be us-central1, us-east1, or us-west1 for Always Free e2-micro"
  type        = string
  default     = "us-central1"

  validation {
    condition     = contains(["us-central1", "us-east1", "us-west1"], var.gcp_region)
    error_message = "GCP e2-micro is only Always Free in us-central1, us-east1, or us-west1."
  }
}

variable "gcp_zone" {
  description = "GCP region — MUST be us-central1, us-east1, or us-west1 for Always Free e2-micro"
  type        = string
  default     = "us-east1-b"

}

# ── Azure ─────────────────────────────────────────────────────────────────────

variable "azure_tenant_id" {
  description = "Azure Entra ID Tenant ID"
  type        = string
  sensitive   = true
}

variable "azure_client_id" {
  description = "Azure Service Principal Client ID (for Terraform)"
  type        = string
  sensitive   = true
}

variable "azure_client_secret" {
  description = "Azure Service Principal Client Secret"
  type        = string
  sensitive   = true
}

# ── Cloudflare ────────────────────────────────────────────────────────────────

variable "cloudflare_api_token" {
  description = "Cloudflare API token with Zone:Edit permissions"
  type        = string
  sensitive   = true
}

variable "cloudflare_zone_id" {
  description = "Cloudflare Zone ID for your domain"
  type        = string
}

# ── Common ───────────────────────────────────────────────────────────────────

variable "domain_name" {
  description = "Your root domain (e.g. example.com)"
  type        = string
}

variable "ssh_public_key" {
  description = "SSH public key to inject into all servers"
  type        = string
}

variable "alert_email" {
  description = "Email address for all budget and alarm notifications"
  type        = string
}

variable "tailscale_auth_key" {
  description = "Tailscale reusable auth key (from tailscale.com/admin/settings/keys)"
  type        = string
  sensitive   = true
}

variable "admin_allowed_cidrs" {
  description = "CIDRs allowed to reach admin interfaces directly (your home/office IPs)"
  type        = list(string)
  default     = ["0.0.0.0/0"] # Tighten this to your IP for production
}

variable "github_org" {
  description = "GitHub username or org name for tagging"
  type        = string
  default     = "your-github-username"
}

variable "github_repo" {
  description = "GitHub repo name"
  type        = string
  default     = "multi-cloud-infra"
}

variable "oci_tailscale_ip" {
  description = "OCI server Tailscale IP (set after first deploy — run: tailscale ip -4 on OCI)"
  type        = string
  default     = "" # Leave empty on first apply; fill in after Tailscale joins
}

variable "uptime_kuma_subdomain" {
  description = "Subdomain for Uptime Kuma status page (proxied via GCP NPM)"
  type        = string
  default     = "status"
}

variable "oci2_private_key" {
  type      = string
  sensitive = true
}


variable "aws_availability_zone" {
  description = "AWS availability zone for the vault EC2 and public subnet"
  type        = string
  default     = "ap-south-1a"
}
