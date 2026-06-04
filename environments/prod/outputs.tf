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
  description = "Uptime Kuma — now on OCI Micro #2, access via Tailscale/WireGuard"
  value       = module.oci_micro2.uptime_kuma_internal_url
}

output "portainer_url" {
  description = "Portainer CE — Docker GUI, access via Tailscale/WireGuard"
  value       = module.oci_micro2.portainer_internal_url
}

# ── OCI ──────────────────────────────────────────────────────────────────────

output "oci_lb_public_ip" {
  description = "OCI Load Balancer public IP — point wg.yourdomain.com here"
  value       = module.oci_lb.public_ip
}

output "oci_wg_nlb_ip" {
  description = "OCI Network Load Balancer IP for WireGuard UDP"
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
  description = "AWS private IP (access via Tailscale or SSM only)"
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
    "wg.yourdomain.com (A, DNS only)"    = module.oci_lb.wg_nlb_public_ip
    "vault.yourdomain.com (A, DNS only)" = "run tailscale ip -4 on AWS after deploy"
  }
}

# ── Post-Deploy Checklist ─────────────────────────────────────────────────────

output "next_steps" {
  description = "Manual steps required after terraform apply"
  value       = <<-STEPS
    ── POST-DEPLOY CHECKLIST ──────────────────────────────────────────

    1. GET TAILSCALE IPs (run on each server after deploy):
       OCI A1:     ssh ubuntu@<a1_private_ip>  → tailscale ip -4
       OCI Micro2: ssh ubuntu@<micro2_private_ip> → tailscale ip -4
       AWS Vault:  connect via AWS SSM → tailscale ip -4
       GCP:        gcloud compute ssh gateway-e2-micro → tailscale ip -4
       → Note all IPs, add oci_tailscale_ip to tfvars, run terraform apply again

    2. PORTAINER — get initial password:
       ssh ubuntu@<micro2_private_ip>
       cat /opt/ops/portainer/admin_password
       Open http://<micro2_tailscale_ip>:9000 (via Tailscale)
       Log in → Settings → Environments → Add Environment → Agent
       Enter OCI A1 private IP:9001 to manage A1 containers from Portainer

    3. UPTIME KUMA — configure monitors (via Tailscale):
       Open http://<micro2_tailscale_ip>:3001
       Add monitors (uses A1 private IP for internal services — no hop):
         OCI A1 — n8n:       http://<a1_private_ip>:5678
         OCI A1 — Ghost:     http://<a1_private_ip>:2368
         OCI A1 — WireGuard: http://<a1_private_ip>:51821
         AWS — Vaultwarden:  http://<aws_tailscale_ip>:8080
         Public — Blog:      https://yourdomain.com
         Public — n8n:       https://n8n.yourdomain.com
         SSL cert — Blog:    (certificate expiry monitor)

    4. VAULTWARDEN — create your account (FIRST TIME ONLY):
       Connect Tailscale on laptop
       Open http://<aws_tailscale_ip>:8080
       Create account → set SIGNUPS_ALLOWED=false

    5. CADDY — set WireGuard admin password hash:
       ssh into OCI A1
       docker exec caddy caddy hash-password
       Update /etc/caddy/Caddyfile, reload: sudo systemctl reload caddy

    6. WIREGUARD — add your devices:
       Open https://wg.yourdomain.com (or http://<a1_tailscale_ip>:51821)
       Click + Add Client → scan QR with WireGuard app

    7. NGINX PROXY MANAGER (GCP — leaner, NPM only):
       Open http://<gcp_public_ip>:81 via Tailscale
       Default login: admin@example.com / changeme → CHANGE IMMEDIATELY
       Add proxy hosts → forward to OCI A1 via Tailscale IP

    8. AZURE SSO — grant admin consent:
       portal.azure.com → Entra ID → Enterprise Applications
       For each app: Permissions → Grant admin consent

    9. VERIFY SECURITY:
       curl http://<aws_public_ip>:8080  → Must timeout (no public vault port)
       curl https://yourdomain.com       → Ghost blog loads
       curl -I yourdomain.com | grep CF-Ray → Confirms Cloudflare proxy
       curl http://<micro2_public_ip>:3001 → Must timeout (Tailscale only)

    ── SERVER SUMMARY ─────────────────────────────────────────────────
    OCI Ampere A1   — WireGuard + n8n + Motibot + Ghost + Caddy
    OCI E2.1.Micro  — Uptime Kuma + Portainer + Watchtower  ← NEW
    AWS t2/t3.micro — Vaultwarden (Tailscale-only, zero public port)
    GCP e2-micro    — Nginx Proxy Manager only  (leaner after move)
    Azure Entra ID  — OIDC SSO (serverless, no compute)
    ───────────────────────────────────────────────────────────────────
  STEPS
}
