# Security Architecture Notes

## Network Security — CIDR Plan

```
10.0.0.0/16      OCI VCN (master)
  10.0.1.0/24    ├── Public subnet  — Load Balancer ONLY
  10.0.2.0/24    └── Private subnet — Ampere A1 + E2.1.Micro #2 (both no public IP)

172.16.0.0/16    AWS VPC (vault)
  172.16.1.0/24  ├── Private subnet — Vaultwarden EC2 (no public IP)
  172.16.2.0/24  └── Public subnet  — NAT Gateway only

192.168.1.0/24   GCP VPC — e2-micro gateway (NPM only)

100.64.0.0/10    Tailscale mesh (RFC 6598 CGNAT range)
10.8.0.0/24      WireGuard client pool
```

## Defense Layers (outermost → innermost)

```
Layer 1:  Cloudflare        — DDoS, CDN, bot protection, SSL termination
Layer 2:  GCP Firewall      — VPC rules, allow 80/443/41641 only
Layer 3:  GCP e2-micro      — Nginx Proxy Manager only (lean), UFW
Layer 4:  Tailscale         — Encrypted mesh, CGNAT addressing
Layer 5:  OCI Security List — Subnet-level allow rules
Layer 6:  OCI NSG           — Per-role NSGs: LB / A1-compute / micro2-ops
Layer 7:  OCI Load Balancer — Only public entry point to private subnet
Layer 8:  UFW (per host)    — Host firewall on A1, Micro #2, AWS, GCP
Layer 9:  Caddy             — TLS termination, reverse proxy, basicauth on /wg
Layer 10: Docker network    — Services on isolated bridge networks (172.20/172.21)
Layer 11: Azure SSO         — OIDC auth gate on n8n + Uptime Kuma + WireGuard UI
```

## NSG Rules Summary

### LB NSG (public subnet)
| Direction | Protocol | Port | Source | Purpose |
|---|---|---|---|---|
| INGRESS | TCP | 80 | 0.0.0.0/0 | HTTP (redirected to HTTPS) |
| INGRESS | TCP | 443 | 0.0.0.0/0 | HTTPS |
| INGRESS | UDP | 51820 | 0.0.0.0/0 | WireGuard |
| EGRESS | ALL | ALL | 0.0.0.0/0 | Outbound |

### Compute NSG (private subnet — Ampere A1)
| Direction | Protocol | Port | Source | Purpose |
|---|---|---|---|---|
| INGRESS | TCP | 80 | LB NSG only | HTTP from LB |
| INGRESS | TCP | 443 | LB NSG only | HTTPS from LB |
| INGRESS | UDP | 51820 | LB NSG only | WireGuard from LB |
| INGRESS | TCP | 22 | Admin CIDRs | SSH (tighten to your IP) |
| INGRESS | UDP | 41641 | 0.0.0.0/0 | Tailscale |
| EGRESS | ALL | ALL | 0.0.0.0/0 | Outbound via NAT GW |

### Micro #2 NSG (private subnet — OCI E2.1.Micro ops node)
| Direction | Protocol | Port | Source | Purpose |
|---|---|---|---|---|
| INGRESS | UDP | 41641 | 0.0.0.0/0 | Tailscale |
| INGRESS | TCP | 9001 | 10.0.0.0/16 | Portainer agent — OCI VCN only (A1 → micro2) |
| INGRESS | TCP | 22 | Admin CIDRs | SSH |
| EGRESS | ALL | ALL | 0.0.0.0/0 | Outbound via NAT GW |
| ❌ NO | TCP | 9000 | 0.0.0.0/0 | Portainer UI — localhost only, Tailscale tunnel |
| ❌ NO | TCP | 3001 | 0.0.0.0/0 | Uptime Kuma — localhost only, Tailscale tunnel |

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
2. **No public port** — `ROCKET_ADDRESS=$TS_IP` binds only to Tailscale IP
3. **Docker port binding** — `"$TS_IP:8080:80"` — Docker only listens on Tailscale IP
4. **AWS Security Group** — port 8080 not listed at all
5. **Private subnet** — EC2 has no public IP
6. **UFW** — no rule for 8080
7. **Access path** — only via WireGuard (phone) or Tailscale (laptop)

To verify isolation after deploy:
```bash
# Must timeout — no public port
curl --connect-timeout 5 http://$(aws ec2 describe-instances \
  --query 'Reservations[].Instances[].PublicIpAddress' \
  --output text):8080

# Must work — via Tailscale
curl http://$(tailscale ip -4 | head -1):8080
```

## Secrets Management

| Secret | Storage | Rotation |
|---|---|---|
| Terraform state | OCI Object Storage (private) | N/A |
| SSH private key | Local only, never committed | Annually |
| OCI API key | Local `~/.oci/`, GitHub Secret | Annually |
| AWS access key | GitHub Secret | 90 days |
| GCP service account key | GitHub Secret (JSON) | Annually |
| Azure client secret | GitHub Secret, expires 2026-12-31 | Annually |
| Tailscale auth key | GitHub Secret | On expiry |
| Cloudflare API token | GitHub Secret | Annually |
| WireGuard passwords | On server only | Quarterly |
| n8n encryption key | Docker env on server | Never rotate (breaks data) |
| Vaultwarden admin token | Docker env on server | Quarterly |

**Never stored in git:**
- `terraform.tfvars`
- `*.pem`, `*.key`
- `terraform.tfstate`

## Monitoring & Alerting

### Uptime Kuma monitors (configure after deploy — now on OCI Micro #2)
Access via Tailscale: `http://<micro2_tailscale_ip>:3001`
Micro #2 is on the same OCI VCN as A1, so internal services are monitored over private IPs — no Tailscale hop latency.
| Monitor | Target | Alert |
|---|---|---|
| OCI — n8n | `http://OCI_TS_IP:5678` | Email + Telegram |
| OCI — Ghost | `http://OCI_TS_IP:2368` | Email |
| OCI — WireGuard UI | `http://OCI_TS_IP:51821` | Email |
| AWS — Vaultwarden | `http://AWS_TS_IP:8080` | Email (critical) |
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
| GCP | $0.50 actual | Monthly | Email |
| GCP | $0.90 actual | Monthly | Email |
| GCP | $1 actual | Monthly | Email + Pub/Sub |
| GCP | $1 forecast | Monthly | Email |
