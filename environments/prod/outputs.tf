###############################################################################
# environments/prod/outputs.tf
# All important outputs after terraform apply
###############################################################################

# ── OCI Micro #2 ─────────────────────────────────────────────────────────────

output "oci_micro2_instance_id" {
  description = "OCI Micro #2 instance OCID"
  value       = module.oci_micro2.instance_id
}

output "oci_micro2_private_ip" {
  description = "OCI Micro #2 private IP (same VCN as A1 — direct internal comms)"
  value       = module.oci_micro2.private_ip
}

output "uptime_kuma_url" {
  description = "Uptime Kuma on OCI Micro #2 — tailnet only"
  value       = module.oci_micro2.uptime_kuma_internal_url
}

output "portainer_url" {
  description = "Portainer CE on OCI Micro #2 — tailnet only"
  value       = module.oci_micro2.portainer_internal_url
}

# ── OCI ──────────────────────────────────────────────────────────────────────

output "oci_lb_public_ip" {
  description = "OCI flexible LB public IP — wg.yourdomain.com (admin UI) points here"
  value       = module.oci_lb.public_ip
}

output "oci_wg_nlb_ip" {
  description = "OCI Network Load Balancer IP — WireGuard clients connect here (UDP 51820)"
  value       = module.oci_lb.wg_nlb_public_ip
}

output "oci_compute_private_ip" {
  description = "Ampere A1 private IP (only reachable via LB or Tailscale)"
  value       = module.oci_compute.private_ip
}

output "oci_instance_id" {
  description = "OCI Compute instance OCID"
  value       = module.oci_compute.instance_id
}

output "oci_vcn_id" {
  description = "OCI VCN OCID"
  value       = module.oci_networking.vcn_id
}

# ── AWS ──────────────────────────────────────────────────────────────────────

output "aws_vault_instance_id" {
  description = "AWS EC2 instance ID for Vaultwarden"
  value       = module.aws_vault.instance_id
}

output "aws_vault_private_ip" {
  description = "AWS private IP (access via Tailscale or SSM Session Manager)"
  value       = module.aws_vault.private_ip
}

output "aws_backup_bucket" {
  description = "S3 bucket name for Vaultwarden backups"
  value       = module.aws_vault.backup_bucket
}

output "aws_budget_sns_arn" {
  description = "SNS topic ARN for billing alerts"
  value       = module.aws_budget.sns_topic_arn
}

# ── GCP ──────────────────────────────────────────────────────────────────────

output "gcp_gateway_public_ip" {
  description = "GCP e2-micro public IP — point yourdomain.com and n8n.yourdomain.com here"
  value       = module.gcp_gateway.public_ip
}

output "gcp_instance_name" {
  description = "GCP Compute Engine instance name"
  value       = module.gcp_gateway.instance_name
}

# ── Azure SSO ─────────────────────────────────────────────────────────────────

output "azure_oidc_issuer" {
  description = "OIDC issuer URL — paste into n8n / Uptime Kuma OIDC config"
  value       = module.azure_sso.oidc_issuer_url
  sensitive   = true
}

output "azure_oidc_metadata_url" {
  description = "OIDC discovery document URL"
  value       = module.azure_sso.oidc_metadata_url
  sensitive   = true
}

output "n8n_oidc_client_id" {
  description = "n8n Azure OIDC client ID"
  value       = module.azure_sso.n8n_client_id
}

output "n8n_oidc_client_secret" {
  description = "n8n Azure OIDC client secret — store in secrets manager"
  value       = module.azure_sso.n8n_client_secret
  sensitive   = true
}

output "uptime_kuma_oidc_client_id" {
  description = "Uptime Kuma Azure OIDC client ID"
  value       = module.azure_sso.uptime_kuma_client_id
}

output "wireguard_oidc_client_id" {
  description = "WireGuard admin Azure OIDC client ID"
  value       = module.azure_sso.wireguard_client_id
}

# ── DNS Summary ───────────────────────────────────────────────────────────────

output "dns_records_summary" {
  description = "DNS records to verify in Cloudflare after apply"
  value = {
    "yourdomain.com (A, proxied)"        = module.gcp_gateway.public_ip
    "www.yourdomain.com (A, proxied)"    = module.gcp_gateway.public_ip
    "n8n.yourdomain.com (A, proxied)"    = module.gcp_gateway.public_ip
    "status.yourdomain.com (A, proxied)" = module.gcp_gateway.public_ip
    "wg.yourdomain.com (A, DNS only)"    = "${module.oci_lb.public_ip} (admin UI via LB; VPN clients use the NLB IP ${module.oci_lb.wg_nlb_public_ip})"
  }
}

output "aws_vault_url" {
  description = "Vaultwarden — tailnet only (HTTPS via tailscale serve)"
  value       = module.aws_vault.tailscale_url
}

# ── Post-Deploy Checklist ─────────────────────────────────────────────────────

output "next_steps" {
  description = "Manual steps required after terraform apply"
  value       = <<-STEPS
    ── POST-DEPLOY CHECKLIST ──────────────────────────────────────────

    0. TAILSCALE: in the admin console enable MagicDNS + HTTPS certificates.
       All admin UIs below are published with `tailscale serve` and are
       reachable ONLY from devices on your tailnet.

    1. TAILSCALE IPs / names (optional — MagicDNS names work directly):
       OCI A1:     ssh ubuntu@oci-a1-apps        → tailscale ip -4
       AWS Vault:  AWS Console → Systems Manager → Session Manager
       GCP:        gcloud compute ssh gateway-e2-micro --tunnel-through-iap
       → add the A1 Tailscale IP as oci_tailscale_ip in tfvars

    2. PORTAINER — https://oci-micro2-ops.<tailnet>.ts.net:8443
       Initial password: ssh ubuntu@oci-micro2-ops
                         sudo cat /opt/ops/portainer/admin_password
       Environments → Add → Agent → <a1_private_ip>:9001 to manage A1

    3. UPTIME KUMA — https://oci-micro2-ops.<tailnet>.ts.net
       Monitor the public endpoints (A1 apps listen on localhost only):
         Public — Blog:  https://yourdomain.com
         Public — n8n:   https://n8n.yourdomain.com
         Vault:          https://aws-vault.<tailnet>.ts.net
         SSL cert expiry monitors for the public hostnames

    4. VAULTWARDEN — https://aws-vault.<tailnet>.ts.net (FIRST TIME ONLY)
       Create your account, then on the instance:
         edit /opt/vaultwarden/docker-compose.yml → SIGNUPS_ALLOWED: "false"
         cd /opt/vaultwarden && sudo docker compose up -d

    5. WIREGUARD — https://wg.yourdomain.com  (Caddy basic auth)
       User: admin   Password: sudo cat /root/wg-admin-password  (on A1)
       + Add Client → scan the QR code with the WireGuard app

    6. NGINX PROXY MANAGER — https://gcp-gateway.<tailnet>.ts.net:8443
       Default login: admin@example.com / changeme → CHANGE IMMEDIATELY
       Add proxy hosts → forward to OCI A1 via its Tailscale IP

    7. AZURE SSO (only if azure_sso_create_apps = true, else MANUAL_SETUP.md):
       portal.azure.com → Entra ID → Enterprise Applications
       For each app: Permissions → Grant admin consent

    8. VERIFY SECURITY:
       curl -m5 http://<aws_eip>:8080        → must time out
       curl -m5 http://<gcp_public_ip>       → must time out (Cloudflare-only)
       curl -I https://yourdomain.com | grep -i cf-ray → proxied via Cloudflare

    ── SERVER SUMMARY ─────────────────────────────────────────────────
    OCI Ampere A1   — WireGuard + n8n + Motibot + Ghost + Caddy
    OCI E2.1.Micro  — Uptime Kuma + Portainer + Watchtower
    OCI tenancy 2   — overflow worker + Vaultwarden standby
    AWS t3.micro    — Vaultwarden (tailnet-only, zero public ports)
    GCP e2-micro    — Nginx Proxy Manager (Cloudflare-only 80/443)
    Azure Entra ID  — optional OIDC app registrations
    ───────────────────────────────────────────────────────────────────
  STEPS
}
