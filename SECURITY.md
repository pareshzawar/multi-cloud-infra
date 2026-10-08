# Security Architecture Notes

## Network Security — CIDR Plan

```
10.0.0.0/16      OCI VCN (master)
  10.0.1.0/24    ├── Public subnet  — Load Balancer ONLY
  10.0.2.0/24    └── Private subnet — Ampere A1 + E2.1.Micro #2 (both no public IP)

172.16.0.0/16    AWS VPC (vault)
  172.16.1.0/24  ├── Vault subnet — Vaultwarden EC2 (routes via IGW, Elastic IP,
                 │                  security group allows NO service ports)
  172.16.2.0/24  └── Spare subnet — empty since the NAT Gateway was removed

192.168.1.0/24   GCP VPC — e2-micro gateway (NPM only)

100.64.0.0/10    Tailscale mesh (RFC 6598 CGNAT range)
10.8.0.0/24      WireGuard client pool
```

## Defense Layers (outermost → innermost)

```
Layer 1:  Cloudflare        — DDoS, CDN, bot protection, SSL termination
Layer 2:  GCP Firewall      — 80/443 from Cloudflare ranges only, UDP 41641
Layer 3:  GCP e2-micro      — Nginx Proxy Manager only (lean), UFW
Layer 4:  Tailscale         — Encrypted mesh; admin UIs via `tailscale serve` (HTTPS)
Layer 5:  OCI Security List — Subnet-level allow rules (attached to both subnets)
Layer 6:  OCI NSG           — Per-role NSGs: LB / A1-compute / micro2-ops
Layer 7:  OCI Load Balancers— Flexible LB (TCP 80/443) + Network LB (UDP 51820)
Layer 8:  Host firewall     — iptables (OCI hosts), UFW (AWS, GCP)
Layer 9:  Caddy             — TLS termination, reverse proxy, basic auth on wg.*
Layer 10: Docker network    — Services on isolated bridge networks (172.20/172.21)

Not a layer (yet): Azure SSO. The Entra ID app registrations exist (optional),
but none of the apps enforce them — see README "Known issues".
```

## NSG Rules Summary

### LB NSG (public subnet — flexible LB)
| Direction | Protocol | Port | Source | Purpose |
|---|---|---|---|---|
| INGRESS | TCP | 80 | 0.0.0.0/0 | HTTP (redirected to HTTPS) |
| INGRESS | TCP | 443 | 0.0.0.0/0 | HTTPS |
| EGRESS | ALL | ALL | 0.0.0.0/0 | Outbound |

The WireGuard Network Load Balancer has no NSG; the public subnet's security
list admits UDP 51820.

### Compute NSG (private subnet — Ampere A1)
| Direction | Protocol | Port | Source | Purpose |
|---|---|---|---|---|
| INGRESS | TCP | 80 | LB NSG only | HTTP from LB |
| INGRESS | TCP | 443 | LB NSG only | HTTPS from LB |
| INGRESS | UDP | 51820 | 10.0.1.0/24 | WireGuard from the Network LB |
| INGRESS | TCP | 9001 | micro2 NSG only | Portainer agent (managed from micro2) |
| INGRESS | TCP | 22 | Admin CIDRs | SSH (default: none — use Tailscale) |
| INGRESS | UDP | 41641 | 0.0.0.0/0 | Tailscale |
| EGRESS | ALL | ALL | 0.0.0.0/0 | Outbound via NAT GW |

### Micro #2 NSG (private subnet — OCI E2.1.Micro ops node)
| Direction | Protocol | Port | Source | Purpose |
|---|---|---|---|---|
| INGRESS | UDP | 41641 | 0.0.0.0/0 | Tailscale |
| INGRESS | TCP | 22 | Admin CIDRs | SSH (default: none — use Tailscale) |
| EGRESS | ALL | ALL | 0.0.0.0/0 | Outbound via NAT GW |
| ❌ NO | TCP | 9000 | 0.0.0.0/0 | Portainer UI — localhost; tailnet via `tailscale serve` :8443 |
| ❌ NO | TCP | 3001 | 0.0.0.0/0 | Uptime Kuma — localhost; tailnet via `tailscale serve` :443 |

### AWS Security Group (Vault EC2)
| Direction | Protocol | Port | Source | Purpose |
|---|---|---|---|---|
| INGRESS | UDP | 41641 | 0.0.0.0/0 | Tailscale |
| INGRESS | TCP | 22 | 100.64.0.0/10 | SSH via Tailscale only |
| EGRESS | ALL | ALL | 0.0.0.0/0 | Outbound |
| ❌ NO | TCP | 8080 | anywhere | Vaultwarden — ZERO public exposure |

## Let's Encrypt / TLS Strategy

Caddy on OCI handles all TLS:

```
Internet
    │  HTTPS
    ▼
OCI Load Balancer (TCP passthrough on 443)
    │  TCP (TLS still encrypted)
    ▼
Caddy on Ampere A1
    │  terminates TLS
    │  auto-renews Let's Encrypt certs
    ├── yourdomain.com → Ghost :2368
    ├── n8n.yourdomain.com → n8n :5678
    └── wg.yourdomain.com → wg-easy :51821 (+ basicauth)
```

Caddy handles:
- ACME HTTP-01 challenge automatically
- Auto-renewal before expiry (checks every 12 hours)
- HSTS headers on all responses
- HTTP → HTTPS redirect (also at LB level)

**Important:** The OCI LB listener on 443 uses `TCP` protocol (not HTTP),
so TLS passthrough reaches Caddy. Caddy terminates TLS and issues the cert.
The LB health check hits port 80 `/health` which Caddy answers with 200.

## Vaultwarden Isolation

Vaultwarden is the most sensitive service. It is protected by:

1. **Physical isolation** — separate AWS account, different cloud provider
2. **Docker port binding** — `"127.0.0.1:8080:80"` — only localhost can connect
3. **Tailnet-only HTTPS** — `tailscale serve` publishes it as
   `https://aws-vault.<tailnet>.ts.net`, reachable only by tailnet members
4. **AWS Security Group** — no service port listed at all (only Tailscale UDP)
5. **UFW** — deny incoming except Tailscale
6. **No public DNS** — there is no `vault.<domain>` record
7. **Access path** — Tailscale (laptop/phone); shell via SSM Session Manager

The instance does have a public IPv4 (Elastic IP) for outbound traffic since
the NAT Gateway was removed; nothing listens on it.

To verify isolation after deploy:
```bash
# Must timeout — no public port
curl --connect-timeout 5 http://$(aws ec2 describe-instances \
  --query 'Reservations[].Instances[].PublicIpAddress' \
  --output text):8080

# Must work — from a device on your tailnet
curl -I https://aws-vault.<your-tailnet>.ts.net
```

## Secrets Management

| Secret | Storage | Rotation |
|---|---|---|
| Terraform state | OCI Object Storage (private) | N/A |
| SSH private key | Local only, never committed | Annually |
| OCI API key | Local `~/.oci/`, GitHub Secret | Annually |
| AWS access key | GitHub Secret | 90 days |
| GCP service account key | GitHub Secret (JSON) | Annually |
| Azure client secret | GitHub Secret; app secrets expire 2027-01-01 | Annually |
| Tailscale auth key | GitHub Secret | On expiry |
| Cloudflare API token | GitHub Secret | Annually |
| WireGuard admin password | `/root/wg-admin-password` on A1 (random at first boot) | Quarterly |
| Portainer initial password | `/opt/ops/portainer/admin_password` on micro2 | Change on first login |
| n8n encryption key | Auto-generated in `/opt/apps/n8n/config` | Never rotate (breaks data) |

**Never stored in git:**
- `terraform.tfvars`
- `*.pem`, `*.key`
- `terraform.tfstate`

## Monitoring & Alerting

### Uptime Kuma monitors (configure after deploy — on OCI Micro #2)
Access from your tailnet: `https://oci-micro2-ops.<tailnet>.ts.net`
A1's apps listen on localhost only, so monitor them through their public URLs.
| Monitor | Target | Alert |
|---|---|---|
| AWS — Vaultwarden | `https://aws-vault.<tailnet>.ts.net` | Email (critical) |
| Public — Blog | `https://yourdomain.com` | Email |
| Public — n8n | `https://n8n.yourdomain.com` | Email |
| SSL — Blog | `https://yourdomain.com` cert expiry | 30 days before |
| SSL — n8n | `https://n8n.yourdomain.com` cert expiry | 30 days before |

### Budget alerts
| Cloud | Threshold | Type | Channel |
|---|---|---|---|
| OCI | $1 actual | Monthly | Email |
| AWS | $0.50 actual | Monthly | Email |
| AWS | $1 actual | Monthly | Email + SNS |
| AWS | $1 forecast | Monthly | Email + SNS |
| GCP | ₹0.50 actual | Monthly | Email |
| GCP | ₹1 actual | Monthly | Email |
| GCP | ₹1 forecast | Monthly | Email |

GCP budgets must use the billing account's currency (INR here), so the GCP
threshold is ₹1 rather than $1.
