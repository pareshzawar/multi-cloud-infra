#cloud-config
# cloud-init.yaml.tpl — Ampere A1 bootstrap
# Installs: Docker · Caddy · Tailscale · WireGuard · n8n · Ghost · Motibot

package_update: true
package_upgrade: true

packages:
  - curl
  - wget
  - git
  - ufw
  - fail2ban
  - unattended-upgrades
  - iptables-persistent

# Open required iptables rules (OCI has internal firewall in addition to Security Lists)
bootcmd:
  - iptables -I INPUT 6 -m state --state NEW -p tcp --dport 80 -j ACCEPT
  - iptables -I INPUT 6 -m state --state NEW -p tcp --dport 443 -j ACCEPT
  - iptables -I INPUT 6 -m state --state NEW -p udp --dport 51820 -j ACCEPT
  - iptables -I INPUT 6 -m state --state NEW -p udp --dport 41641 -j ACCEPT
  - netfilter-persistent save

write_files:
  # ── Docker Compose: all services ──────────────────────────────────────────
  - path: /opt/apps/docker-compose.yml
    permissions: '0644'
    content: |
      version: '3.8'

      networks:
        internal:
          driver: bridge
          ipam:
            config:
              - subnet: 172.20.0.0/24

      services:

        # ── WireGuard VPN (wg-easy) ─────────────────────────────────────
        wireguard:
          image: ghcr.io/wg-easy/wg-easy:latest
          container_name: wireguard
          restart: unless-stopped
          networks: [internal]
          environment:
            WG_HOST: "${wireguard_host_ip}"
            WG_PORT: "51820"
            WG_DEFAULT_DNS: "1.1.1.1,8.8.8.8"
            WG_ALLOWED_IPS: "0.0.0.0/0"
            UI_PORT: "51821"
            PASSWORD_HASH: ""   # Set via: wgpw YOUR_PASSWORD → paste hash here
          volumes:
            - ./wireguard:/etc/wireguard
          ports:
            - "51820:51820/udp"
            - "51821:51821/tcp"
          cap_add:
            - NET_ADMIN
            - SYS_MODULE
          sysctls:
            - net.ipv4.ip_forward=1
            - net.ipv4.conf.all.src_valid_mark=1

        # ── n8n Workflow Automation ──────────────────────────────────────
        n8n:
          image: n8nio/n8n:latest
          container_name: n8n
          restart: unless-stopped
          networks: [internal]
          environment:
            N8N_HOST: "${n8n_subdomain}"
            N8N_PORT: "5678"
            N8N_PROTOCOL: "https"
            WEBHOOK_URL: "https://${n8n_subdomain}/"
            GENERIC_TIMEZONE: "Asia/Kolkata"
            DB_TYPE: "sqlite"
            N8N_ENCRYPTION_KEY: ""          # Generate: openssl rand -hex 32
            # Azure SSO via OIDC
            N8N_EXTERNAL_SECRETS_ENABLED: "true"
            OIDC_ENABLED: "true"
            OIDC_ISSUER: "https://login.microsoftonline.com/${azure_tenant_id}/v2.0"
            OIDC_CLIENT_ID: "${n8n_oidc_client_id}"
            OIDC_CLIENT_SECRET: "${n8n_oidc_secret}"
            OIDC_REDIRECT_URL: "https://${n8n_subdomain}/rest/oauth2-credential/callback"
          volumes:
            - ./n8n:/home/node/.n8n
          ports:
            - "127.0.0.1:5678:5678"   # Only localhost — Caddy proxies

        # ── Motibot ──────────────────────────────────────────────────────
        motibot:
          image: motibot/motibot:latest
          container_name: motibot
          restart: unless-stopped
          networks: [internal]
          environment:
            TZ: "Asia/Kolkata"
          volumes:
            - ./motibot/config:/app/config
            - ./motibot/data:/app/data
          ports:
            - "127.0.0.1:3000:3000"

        # ── Ghost Blog ────────────────────────────────────────────────────
        ghost:
          image: ghost:5-alpine
          container_name: ghost
          restart: unless-stopped
          networks: [internal]
          environment:
            url: "https://${domain_name}"
            database__client: "sqlite3"
            database__connection__filename: "/var/lib/ghost/content/data/ghost.db"
            mail__transport: "Direct"
            NODE_ENV: "production"
          volumes:
            - ./ghost:/var/lib/ghost/content
          ports:
            - "127.0.0.1:2368:2368"

  # ── Caddy config — TLS termination + reverse proxy ────────────────────────
  - path: /etc/caddy/Caddyfile
    permissions: '0644'
    content: |
      # Global options
      {
        email admin@${domain_name}
        # ACME challenge — Let's Encrypt auto TLS
        acme_ca https://acme-v02.api.letsencrypt.org/directory
      }

      # Health check endpoint for OCI LB
      :80 {
        respond /health 200
        redir https://{host}{uri} permanent
      }

      # Root domain → Ghost blog
      ${domain_name} {
        reverse_proxy localhost:2368
        encode gzip
        header {
          Strict-Transport-Security "max-age=31536000; includeSubDomains"
          X-Content-Type-Options nosniff
          X-Frame-Options DENY
          X-XSS-Protection "1; mode=block"
          Referrer-Policy strict-origin-when-cross-origin
        }
      }

      www.${domain_name} {
        redir https://${domain_name}{uri} permanent
      }

      # n8n — protected by Azure SSO at app level
      ${n8n_subdomain} {
        reverse_proxy localhost:5678
        encode gzip
      }

      # WireGuard admin UI — Caddy adds basic auth layer
      ${wg_subdomain} {
        reverse_proxy localhost:51821
        basicauth {
          # Generate with: caddy hash-password --plaintext YOUR_PASSWORD
          admin $2a$14$CHANGEME_RUN_caddy_hash-password
        }
      }

  # ── Systemd service for Docker Compose ────────────────────────────────────
  - path: /etc/systemd/system/apps.service
    permissions: '0644'
    content: |
      [Unit]
      Description=Multi-cloud app stack
      Requires=docker.service
      After=docker.service network.target tailscaled.service

      [Service]
      Type=oneshot
      RemainAfterExit=yes
      WorkingDirectory=/opt/apps
      ExecStart=/usr/bin/docker compose up -d --remove-orphans
      ExecStop=/usr/bin/docker compose down
      TimeoutStartSec=300

      [Install]
      WantedBy=multi-user.target

runcmd:
  # ── Install Docker ─────────────────────────────────────────────────────────
  - curl -fsSL https://get.docker.com | sh
  - usermod -aG docker ubuntu
  - systemctl enable docker
  - systemctl start docker

  # ── Install Caddy ──────────────────────────────────────────────────────────
  - apt install -y debian-keyring debian-archive-keyring apt-transport-https
  - curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
  - curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | tee /etc/apt/sources.list.d/caddy-stable.list
  - apt update && apt install -y caddy
  - systemctl enable caddy
  - systemctl start caddy

  # ── Install Tailscale ──────────────────────────────────────────────────────
  - curl -fsSL https://tailscale.com/install.sh | sh
  - tailscale up --authkey=${tailscale_auth_key} --hostname=oci-a1-apps --accept-routes
  - systemctl enable tailscaled

  # ── Create app directories ─────────────────────────────────────────────────
  - mkdir -p /opt/apps/{wireguard,n8n,motibot/config,motibot/data,ghost}
  - chown -R ubuntu:ubuntu /opt/apps

  # ── Start apps ────────────────────────────────────────────────────────────
  - systemctl daemon-reload
  - systemctl enable apps.service
  - systemctl start apps.service

  # ── Configure UFW ─────────────────────────────────────────────────────────
  - ufw default deny incoming
  - ufw default allow outgoing
  - ufw allow 80/tcp
  - ufw allow 443/tcp
  - ufw allow 51820/udp
  - ufw allow 41641/udp
  - ufw --force enable

  # ── Swapfile (not needed on 24 GB, but defensive) ─────────────────────────
  - fallocate -l 2G /swapfile
  - chmod 600 /swapfile
  - mkswap /swapfile
  - swapon /swapfile
  - echo '/swapfile none swap sw 0 0' >> /etc/fstab

final_message: "OCI Ampere A1 bootstrap complete. Services starting..."
