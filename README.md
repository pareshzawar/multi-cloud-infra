# 🏗️ Multi-Cloud Zero-Cost Infrastructure — Plan B

> **OCI Ampere A1 · OCI E2.1.Micro · AWS t2/t3.micro · GCP e2-micro**
> Defense-in-Depth · Tailscale Mesh · Azure Entra SSO · Full Terraform IaC

## Architecture

```
Internet
   │
   ▼
Cloudflare (Free CDN + DDoS)
   │
   ▼
GCP e2-micro ──── Public Gateway only (Nginx Proxy Manager)
   │                    │
   │              Tailscale Mesh (100.x.x.x private IPs)
   │     ┌──────────────┬──────────────────────────────┐
   │     ▼              ▼                              ▼
   │  OCI Ampere A1   OCI E2.1.Micro #2          AWS t2/t3.micro
   │  ├── WireGuard   ├── Uptime Kuma             └── Vaultwarden
   │  ├── n8n         ├── Portainer CE                 (Tailscale-only)
   │  ├── Motibot     ├── Watchtower
   │  ├── Ghost Blog  └── Fail2ban syslog
   │  └── Caddy (TLS)
   │
   ▼
Azure Entra ID (Free OIDC SSO)
   └── Secures: n8n · Uptime Kuma · WireGuard Admin
```

## What's Included

| Layer | What | Provider |
|---|---|---|
| Networking | VCN, public subnet, private subnet, IGW, NAT GW, Service GW | OCI |
| Compute #1 | Ampere A1 (4 OCPU / 24 GB) — apps | OCI |
| Compute #2 | E2.1.Micro (1 OCPU / 1 GB) — ops & monitoring | OCI |
| Load Balancer | Flexible LB (10 Mbps Always Free) — HTTP→HTTPS + SSL offload | OCI |
| Security | NSG per role (LB / compute / micro2), Security Lists | OCI |
| TLS | Caddy + Let's Encrypt (auto-renew) on OCI A1 | OCI |
| Vault | Vaultwarden on isolated t2/t3.micro, Tailscale-only | AWS |
| Backups | S3 bucket (encrypted) for Vaultwarden DB | AWS |
| Gateway | Nginx Proxy Manager on e2-micro (NPM only — lean) | GCP |
| Monitoring | Uptime Kuma on OCI Micro #2 (same VCN as A1 — lower latency) | OCI |
| Docker GUI | Portainer CE on OCI Micro #2 | OCI |
| Auto-updates | Watchtower on OCI Micro #2 (centralised) | OCI |
| CDN | Cloudflare (managed via Terraform) | Cloudflare |
| SSO | Azure Entra ID OIDC — secures n8n, Uptime Kuma, WireGuard UI | Azure |
| Budget Alerts | $1 threshold alerts with email notifications | OCI + AWS + GCP |
| IaC | Full Terraform — all resources declarative | All |
| CI/CD | GitHub Actions — `terraform plan` on PR, `apply` on merge to main | GitHub |

## CIDR Addressing Plan

| Network | CIDR | Purpose |
|---|---|---|
| OCI VCN | `10.0.0.0/16` | Master CIDR |
| OCI Public Subnet | `10.0.1.0/24` | Load Balancer only |
| OCI Private Subnet | `10.0.2.0/24` | Ampere A1 + E2.1.Micro #2 |
| AWS VPC | `172.16.0.0/16` | Vault network |
| AWS Private Subnet | `172.16.1.0/24` | Vaultwarden |
| GCP VPC | `192.168.1.0/24` | Gateway |
| Tailscale Mesh | `100.64.0.0/10` | Inter-cloud private |
| WireGuard Clients | `10.8.0.0/24` | VPN client IPs |

## Quick Start

### 1. Prerequisites

```bash
# Install Terraform
brew install terraform   # macOS
# or: https://developer.hashicorp.com/terraform/downloads

# Install required CLIs
brew install oci-cli awscli
pip install --user google-cloud-sdk

# Authenticate all providers
oci setup config
aws configure
gcloud auth application-default login
```

### 2. Configure secrets

```bash
cp environments/prod/terraform.tfvars.example environments/prod/terraform.tfvars
# Edit terraform.tfvars with your actual values (never commit this file)
```

### 3. Deploy

```bash
cd environments/prod
terraform init
terraform plan
terraform apply
```

## Repository Structure

```
infra/
├── README.md
├── .gitignore                    # Excludes .tfvars, .tfstate, secrets
├── .github/
│   └── workflows/
│       └── terraform.yml         # CI/CD: plan on PR, apply on merge
├── environments/
│   └── prod/
│       ├── main.tf               # Root module — wires everything together
│       ├── variables.tf          # Input variable declarations
│       ├── outputs.tf            # Outputs: IPs, endpoints, post-deploy checklist
│       └── terraform.tfvars.example
└── modules/
    ├── oci-networking/           # VCN, subnets, IGW, NAT GW, Service GW
    ├── oci-security/             # NSGs (LB / compute / micro2), Security Lists
    ├── oci-lb/                   # Flexible LB + HTTP→HTTPS + WireGuard NLB
    ├── oci-compute/              # Ampere A1 — apps (n8n, Motibot, Ghost, WG, Caddy)
    ├── oci-micro2/               # E2.1.Micro #2 — ops (Uptime Kuma, Portainer, Watchtower)
    ├── oci-budget/               # OCI budget alert at $1
    ├── aws-vault/                # VPC, EC2 private, S3 encrypted, IAM for Vaultwarden
    ├── aws-budget/               # AWS budget: 50%/100% actual + forecast + CloudWatch
    ├── gcp-gateway/              # VPC, e2-micro, Nginx Proxy Manager only (lean)
    ├── gcp-budget/               # GCP budget: 50%/90%/100% actual + forecast
    └── azure-sso/                # Entra ID OIDC apps: n8n, Uptime Kuma, WireGuard
```

## Security Notes

- Vaultwarden has **zero public ports** — bound to Tailscale IP only
- OCI compute lives in **private subnet** — only reachable via Load Balancer
- NSGs use **allow-list model** — deny all by default, explicit allows only
- All inter-cloud traffic goes through **Tailscale encrypted mesh**
- Secrets are in `terraform.tfvars` which is **git-ignored**
- State file is stored in **OCI Object Storage** (free) with state locking

## Azure SSO — What's Free

Azure Entra ID Free tier includes unlimited OIDC/OAuth2 SSO for your own applications.
What you get for free:
- App registrations (unlimited)
- OIDC / OAuth2 / SAML SSO
- MFA via Microsoft Authenticator

What requires paid tier (P1/P2):
- Conditional Access policies
- Identity Protection
- Privileged Identity Management

For this stack, the **free tier is sufficient** — OIDC SSO protects all admin UIs.

## Budget Alerts Summary

| Cloud | Alert Threshold | Notification |
|---|---|---|
| OCI | $1.00 / month | Email |
| AWS | $1.00 / month | Email (CloudWatch) |
| GCP | $1.00 / month | Email (Budget API) |
