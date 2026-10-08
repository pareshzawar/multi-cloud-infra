# 🏗️ Multi-Cloud Zero-Cost Infrastructure — Plan B

> **OCI Ampere A1 · OCI E2.1.Micro · AWS t2/t3.micro · GCP e2-micro**
> Defense-in-Depth · Tailscale Mesh · Azure Entra ID · Full Terraform IaC

> **Status: archived lab snapshot (June 2026), reviewed and corrected in a
> later pass.** The code passes `terraform fmt -check` and `terraform validate`
> in CI, and every boot script renders and parses. It has **not** been
> re-applied end-to-end since those fixes. CI never provisions anything on
> its own (see [CI/CD safety](#cicd-safety)). What is still open is listed
> under [Known issues & lessons learned](#known-issues--lessons-learned).

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
Azure Entra ID (optional OIDC app registrations — not enforced, see Known issues)
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
| Monitoring | Uptime Kuma on OCI Micro #2, tailnet-only via `tailscale serve` | OCI |
| Docker GUI | Portainer CE on OCI Micro #2 | OCI |
| Auto-updates | Watchtower on OCI Micro #2 (centralised) | OCI |
| CDN | Cloudflare (managed via Terraform) | Cloudflare |
| Identity | Azure Entra ID OIDC app registrations (optional; not enforced by the apps yet) | Azure |
| Budget Alerts | $1 (OCI, AWS) / ₹1 (GCP) threshold alerts by email | OCI + AWS + GCP |
| IaC | Full Terraform — all resources declarative | All |
| CI/CD | GitHub Actions — `validate` on PR/merge; plan/apply manual + approval only | GitHub |

## CIDR Addressing Plan

| Network | CIDR | Purpose |
|---|---|---|
| OCI VCN | `10.0.0.0/16` | Master CIDR |
| OCI Public Subnet | `10.0.1.0/24` | Load Balancer only |
| OCI Private Subnet | `10.0.2.0/24` | Ampere A1 + E2.1.Micro #2 |
| AWS VPC | `172.16.0.0/16` | Vault network |
| AWS Vault Subnet | `172.16.1.0/24` | Vaultwarden (IGW + Elastic IP, no service ports) |
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
brew install --cask google-cloud-sdk   # or: https://cloud.google.com/sdk/docs/install

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
terraform init      # needs the OCI state keys, see backend.tf
terraform plan      # READ this before applying
terraform apply
```

Or use the manual GitHub Actions workflow (plan, then approved apply) — see
[CI/CD safety](#cicd-safety).

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
    ├── oci-compute2/             # Tenancy 2 — overflow worker + Vaultwarden standby
    ├── oci-budget/               # OCI budget alert at $1
    ├── remote-state-bootstrap/   # One-off: state bucket + S3-compatible keys
    ├── aws-vault/                # VPC, EC2 + Elastic IP, S3 encrypted, IAM/SSM for Vaultwarden
    ├── aws-budget/               # AWS budgets: 50%/100% actual + forecast → email + SNS
    ├── gcp-gateway/              # VPC, e2-micro, Nginx Proxy Manager only (lean)
    ├── gcp-budget/               # GCP budget: 50%/90%/100% actual + forecast
    └── azure-sso/                # Entra ID OIDC apps: n8n, Uptime Kuma, WireGuard
```

## Security Notes

- Vaultwarden has **zero public ports** — localhost-bound, published to the tailnet with `tailscale serve`
- OCI compute lives in **private subnets** — public traffic only via the load balancers
- Security lists **and** NSGs use an **allow-list model**; both are attached
- GCP gateway accepts 80/443 **from Cloudflare only**
- All inter-cloud traffic goes through the **Tailscale encrypted mesh**
- Secrets are in `terraform.tfvars` (git-ignored) or GitHub Secrets
- State is stored in **OCI Object Storage** (free, versioned) — **no state locking**, see Known issues

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

The free tier is enough to *register* the apps. Enforcing SSO is a separate
problem: see Known issues. App creation is off by default
(`azure_sso_create_apps = false`); see MANUAL_SETUP.md for the portal route.

## Budget Alerts Summary

| Cloud | Alert Threshold | Notification |
|---|---|---|
| OCI | $1.00 / month | Email |
| AWS | $1.00 / month | Email + SNS (AWS Budgets) |
| GCP | ₹1 / month (billing account is INR) | Email (Budget API) |

## CI/CD safety

Opening or merging a PR **cannot create, change or destroy infrastructure**.

| Trigger | What runs | Cloud credentials |
|---|---|---|
| Pull request → `main` | `fmt -check`, `init -backend=false`, `validate` | none |
| Push / merge to `main` | same as above | none |
| Manual run, `action=plan` | `terraform plan` (read-only) | yes |
| Manual run, `action=apply` + `confirm=APPLY`, from `main` | plan → **production environment approval** → `apply` of that exact saved plan | yes |

## Known issues & lessons learned

A later review found and fixed the bugs listed in the commit history (the
stack did not pass `terraform validate`, WireGuard could not connect,
several boot scripts aborted, and more). The items below are **still open**,
mostly design trade-offs. They are kept here on purpose, as notes for whoever
picks this up.

**Architecture**
- **Two TLS front doors for the same hostnames.** DNS points `@`, `www`,
  `n8n` and `status` at the GCP Nginx Proxy Manager, while Caddy on OCI A1
  also tries to get Let's Encrypt certificates for those names through the
  OCI load balancer. Only one can win an HTTP-01 challenge. Pick one: either
  NPM terminates TLS and proxies to A1 over Tailscale, or DNS points at the
  OCI LB and the GCP hop goes away.
- **SSO is not enforced.** n8n's OIDC login needs an Enterprise licence;
  Uptime Kuma and wg-easy have no OIDC support. Admin UIs are protected by
  Tailscale (tailnet-only) and Caddy basic auth instead. Real SSO would mean
  putting something like `oauth2-proxy` in front of them.
- **No Terraform state locking.** The S3-compatible OCI backend has no lock
  table, and Terraform 1.7 has no `use_lockfile`. CI serialises runs with a
  `concurrency` group; local runs must not overlap with CI.

**Secrets and supply chain**
- The Tailscale auth key is rendered into instance user-data, so it sits in
  instance metadata and in Terraform state. Prefer short-lived, tagged,
  pre-approved keys, or pull secrets from a vault at boot.
- One reusable Tailscale key is shared by every node, and no tailnet ACLs or
  tags are defined.
- Hosts bootstrap with `curl … | sh` installers (Docker, Tailscale, rclone).
- Several images float (`n8nio/n8n:latest`, `motibot/motibot:latest`,
  `jc21/nginx-proxy-manager:latest`, `containrrr/watchtower:latest`), and
  Watchtower auto-updates them. `motibot/motibot` is not verified to exist.
  Pin digests for reproducibility.

**Hardening still to do**
- Tenancy-2 instances have public IPs with SSH open to `0.0.0.0/0` (key-only).
  Restrict it to Tailscale once the mesh is proven.
- Vaultwarden starts with `SIGNUPS_ALLOWED=true` (tailnet-only) until you
  flip it after creating your account.
- `aws-vault` hard-codes its SSH public key and subnet layout on purpose, to
  match live state without forcing a replacement.

**Cost and lifecycle**
- AWS charges for public IPv4 addresses, including Elastic IPs, beyond the
  free-tier allowance. The t3.micro free tier is time-limited; tenancy 2 is
  the planned landing spot for Vaultwarden (see `oci-compute2`).
- GCP VPC flow logs (50% sampling) go to Cloud Logging and can exceed the
  free allotment on a busy gateway.
- Ubuntu 22.04 standard support ends in April 2027.
- Always Free Ampere A1 capacity is often unavailable ("out of host
  capacity") in popular regions.

**If you re-apply this snapshot**
- Run a manual **plan** first and read it. Expect in-place changes:
  - security lists get attached to the subnets (the `moved` blocks avoid a
    recreate);
  - NSG rules change;
  - the public `vault` DNS record is deleted;
  - the GCP VM's service-account scopes change, which **stops and starts**
    the gateway once.
- Boot-script fixes only reach new instances. Existing ones ignore
  `user_data` changes so that `prevent_destroy` holds.
- Admin UIs need MagicDNS and HTTPS certificates enabled in the Tailscale
  admin console for `tailscale serve`.
