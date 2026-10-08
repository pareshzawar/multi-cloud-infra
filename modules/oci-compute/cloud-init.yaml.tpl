#cloud-config
# cloud-init.yaml.tpl — Ampere A1 bootstrap
# Installs: Docker · Caddy · Tailscale · WireGuard · n8n · Ghost · Motibot

package_update: true
package_upgrade: true

# Host firewall: OCI Ubuntu images ship iptables rules managed by
# iptables-persistent. We keep that and do NOT install ufw — the ufw package
# declares "Breaks: iptables-persistent", so installing both fails.
packages:
  - curl
  - wget
  - git
  - fail2ban
  - unattended-upgrades
  - iptables-persistent

write_files:
  # ── Docker Compose: all services ──────────────────────────────────────────
  - path: /opt/apps/docker-compose.yml
    permissions: '0644'
    content: |
      networks:
        internal:
          driver: bridge
          ipam:
            config:
              - subnet: 172.20.0.0/24

      services:

        # ── WireGuard VPN (wg-easy) ─────────────────────────────────────
        # Pinned to v14: v15 replaced these env vars with a web setup wizard.
        wireguard:
          image: ghcr.io/wg-easy/wg-easy:14
          container_name: wireguard
          restart: unless-stopped
          networks: [internal]
          environment:
            WG_HOST: "${wireguard_host_ip}"
            WG_PORT: "51820"
            WG_DEFAULT_DNS: "1.1.1.1,8.8.8.8"
            WG_ALLOWED_IPS: "0.0.0.0/0"
            UI_PORT: "51821"
            # No PASSWORD_HASH: the UI is bound to localhost and only reachable
            # through Caddy, which enforces basic auth (see Caddyfile).
          volumes:
            - ./wireguard:/etc/wireguard
          ports:
            - "51820:51820/udp"
            - "127.0.0.1:51821:51821/tcp"   # UI: localhost only, Caddy proxies
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
            # N8N_ENCRYPTION_KEY is left unset on purpose: n8n generates one on
            # first start and stores it in /home/node/.n8n/config. (An empty
            # string here would be treated as a real, empty key.)
            # Login: n8n's own user management. n8n OIDC/SSO is an Enterprise
            # licence feature and is not configured via env vars, so the
            # previous OIDC_* variables did nothing.
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

        # ── Portainer Agent ──────────────────────────────────────────────
        # Lets Portainer on OCI Micro #2 manage this host's containers.
        # Port 9001 is opened in the compute NSG to the micro2 NSG only.
        portainer-agent:
          image: portainer/agent:2.21.5
          container_name: portainer-agent
          restart: unless-stopped
          ports:
            - "9001:9001"
          volumes:
            - /var/run/docker.sock:/var/run/docker.sock
            - /var/lib/docker/volumes:/var/lib/docker/volumes

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

      # Health check endpoint for the OCI load balancers.
      # Caddy runs "redir" before "respond" regardless of file order, so the
      # two must be in separate handle blocks or /health gets redirected.
      :80 {
        handle /health {
          respond 200
        }
        handle {
          redir https://{host}{uri} permanent
        }
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

      # WireGuard admin UI — Caddy basic auth is the only login in front of
      # it. The placeholder below is replaced at first boot with the bcrypt hash of a
      # random password saved to /root/wg-admin-password (see runcmd).
      ${wg_subdomain} {
        basic_auth {
          admin WG_ADMIN_HASH
        }
        reverse_proxy localhost:51821
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

  # ── Host firewall (iptables, persisted) ────────────────────────────────────
  # Runs once, after packages are installed (bootcmd ran before
  # iptables-persistent existed and re-inserted duplicates on every boot).
  - iptables -I INPUT 6 -m state --state NEW -p tcp --dport 80 -j ACCEPT
  - iptables -I INPUT 6 -m state --state NEW -p tcp --dport 443 -j ACCEPT
  - iptables -I INPUT 6 -m state --state NEW -p udp --dport 51820 -j ACCEPT
  - iptables -I INPUT 6 -m state --state NEW -p udp --dport 41641 -j ACCEPT
  - iptables -I INPUT 6 -m state --state NEW -p tcp --dport 9001 -s 10.0.0.0/16 -j ACCEPT
  - netfilter-persistent save

  # ── Install Caddy ──────────────────────────────────────────────────────────
  - apt-get install -y debian-keyring debian-archive-keyring apt-transport-https
  - curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
  - curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | tee /etc/apt/sources.list.d/caddy-stable.list
  # --force-confold keeps OUR /etc/caddy/Caddyfile (written above) instead of
  # stopping at dpkg's "config file changed" prompt, which has no TTY here.
  - apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y -o Dpkg::Options::=--force-confold caddy
  # Generate the WireGuard admin password and put its hash into the Caddyfile.
  # Subshell so the strict umask does not leak into the rest of runcmd
  # (cloud-init runs all runcmd entries as one script).
  - (umask 077 && openssl rand -base64 24 > /root/wg-admin-password)
  - sed -i "s|WG_ADMIN_HASH|$(caddy hash-password --plaintext "$(cat /root/wg-admin-password)")|" /etc/caddy/Caddyfile
  - systemctl enable caddy
  - systemctl restart caddy

  # ── Install Tailscale ──────────────────────────────────────────────────────
  - curl -fsSL https://tailscale.com/install.sh | sh
  - tailscale up --authkey=${tailscale_auth_key} --hostname=oci-a1-apps --accept-routes
  - systemctl enable tailscaled

  # ── Create app directories ─────────────────────────────────────────────────
  # Listed one by one: runcmd uses /bin/sh, which has no {a,b} brace expansion.
  # They must exist (owned by uid 1000) BEFORE compose starts, otherwise Docker
  # creates them as root and n8n/Ghost (uid 1000) cannot write their data.
  - mkdir -p /opt/apps/wireguard /opt/apps/n8n /opt/apps/motibot/config /opt/apps/motibot/data /opt/apps/ghost
  - chown -R ubuntu:ubuntu /opt/apps

  # ── Start apps ────────────────────────────────────────────────────────────
  - systemctl daemon-reload
  - systemctl enable apps.service
  - systemctl start apps.service

  # ── Swapfile (not needed on 24 GB, but defensive) ─────────────────────────
  - fallocate -l 2G /swapfile
  - chmod 600 /swapfile
  - mkswap /swapfile
  - swapon /swapfile
  - echo '/swapfile none swap sw 0 0' >> /etc/fstab

final_message: "OCI Ampere A1 bootstrap complete. Services starting..."
