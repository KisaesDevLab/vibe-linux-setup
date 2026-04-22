# Vibe Linux Setup — Kisaes LLC

Automated provisioning for Ubuntu Server 24.04 LTS machines running the Kisaes application stack. Idempotent single-shot installer — re-runnable if anything fails mid-way, and safe against re-runs once everything's up.

## What Gets Installed

| Service | Purpose | Access |
|---|---|---|
| **Vibe Trial Balance** | Trial balance, tax workpapers, AI classification | `http://tb.kisaes.local/` |
| **Vibe MyBooks** | Bookkeeping, transaction coding, client portal | `http://mb.kisaes.local/` |
| **Vibe Payroll Time** | Time tracking, payroll runs, QR badge punch-ins | `http://pt.kisaes.local/` |
| **Landing page** | Card-selector for the three apps | `http://kisaes.local/` |
| **GLM-OCR** | Self-hosted OCR appliance (llama.cpp + GLM-OCR GGUF) | `http://127.0.0.1:8090/` (host-only) |
| **Webmin** | Web-based server + network management | `https://<ip>:10000` |
| **Portainer CE** | Docker container management UI | `https://<ip>:9443` |
| **Duplicati** | Scheduled backups | `http://<ip>:8200` |
| **Tailscale** | Mesh VPN for secure remote access | All services via `100.x.x.x` |
| **Nginx** | Reverse proxy (hostname-based) | Port 80 |
| **Avahi mDNS** | Publishes `.local` hostnames to the LAN | UDP 5353 |
| **UFW** | Firewall for host-level ports | — |

## Quick Start

On a fresh Ubuntu Server 24.04 LTS box:

```bash
curl -fsSL https://raw.githubusercontent.com/KisaesDevLab/vibe-Linux-Setup/main/bootstrap.sh | bash
```

`bootstrap.sh` installs git, clones this repo, and runs `provision.sh`, which executes every phase end-to-end (base packages + Avahi, Docker, shared network, GLM-OCR, Vibe TB, Vibe MB, Vibe PT, Portainer, Duplicati, Tailscale, Webmin, landing page, nginx, mDNS aliases, IP:port fallback listeners, UFW, verification). It also installs Claude Code for ongoing maintenance.

The script is **idempotent** — containers, volumes, secrets, and firewall rules all no-op if they already exist, so re-running after a failure resumes cleanly.

### Unattended mode

Provide a Tailscale pre-auth key to skip the interactive browser-auth step:

```bash
curl -fsSL https://raw.githubusercontent.com/KisaesDevLab/vibe-Linux-Setup/main/bootstrap.sh \
  | TAILSCALE_AUTHKEY=tskey-auth-xxxxx bash
```

Tailscale auth has a 10-minute timeout — if no key is provided and nobody clicks the browser URL, the phase gives up and provisioning finishes. Resume later with `sudo tailscale up --ssh --accept-dns`.

### Environment overrides

- `VIBE_DOMAIN` — base hostname (default `kisaes.local`). The four services are served as:
  - `http://<VIBE_DOMAIN>/` → landing page
  - `http://tb.<VIBE_DOMAIN>/` → Vibe Trial Balance
  - `http://mb.<VIBE_DOMAIN>/` → Vibe MyBooks
  - `http://pt.<VIBE_DOMAIN>/` → Vibe Payroll Time

  A `.local` domain is published automatically via mDNS (avahi) and resolves on every modern client with zero client-side DNS config (see [DNS resolution](#dns-resolution) below). Any other TLD works but you must configure DNS yourself (router, Pi-hole, `/etc/hosts`, or Tailscale Split DNS).

- `TAILSCALE_AUTHKEY` — pre-auth key for unattended Tailscale registration.
- `LOG_FILE` — path for the provisioning log (default `~/vibe-provision.log`).

### Flags

- `--skip-tailscale` — skip the Tailscale phase entirely.
- `--skip-claude` — skip installing Claude Code.

### Running locally after clone

```bash
cd ~/vibe-Linux-Setup
./provision.sh
```

## Requirements

- **Hardware:** x86_64 mini PC (tested on GMKtec NucBox M6)
- **OS:** Ubuntu Server 24.04 LTS (clean install)
- **RAM:** 12 GB minimum, **16 GB recommended.** GLM-OCR alone is ~2–4 GB resident; add Vibe TB server (1 GB heap), two Postgres + Redis, and Vibe MB which bundles Puppeteer + Chromium (~500 MB–1 GB at runtime for PDF generation) and concurrent light use easily tops 6–7 GB before headroom.
- **Storage:** 40 GB+ available
- **Network:** Internet connection during provisioning (for apt, Docker Hub, GHCR, Tailscale)

## DNS resolution

With the default `kisaes.local` domain, provisioning publishes three mDNS A-records and every modern client resolves them without further config:

- **macOS / iOS / Android 12+** — native mDNS, works out of the box.
- **Ubuntu / most Linux desktops** — `nss-mdns` talks to avahi via `/etc/nsswitch.conf`. Works on install.
- **Windows 10 1803+ / Windows 11** — native mDNS resolver in the DNS Client service. **Set the network profile to Private, not Public** — Windows Defender Firewall blocks inbound mDNS on Public. `nslookup` won't find it (nslookup is unicast-only); use `ping kisaes.local` or `Resolve-DnsName kisaes.local` to test.
- **Windows 7/8** — install Bonjour Print Services (rare in 2026).

### Fallback when mDNS doesn't work

mDNS doesn't traverse Tailscale and may be blocked on corporate networks or VLANs. The final phase of `provision.sh` prints exact `/etc/hosts` entries for both your LAN IP and (if present) your Tailscale IP. Or use Tailscale split-DNS: Machines → DNS → Split DNS → add `kisaes.local` pointing to the Tailscale IP.

## Architecture

```
┌──────────────────────────── Port 80 (host nginx) ──────────────────────────┐
│                                                                            │
│  Host: kisaes.local      → /var/www/kisaes/index.html (landing)            │
│  Host: tb.kisaes.local   → 127.0.0.1:3000 → vibe-tb-client (nginx + SPA)  │
│                                           → vibe-tb-server (Node API)     │
│                                           → vibe-tb-db (Postgres)         │
│  Host: mb.kisaes.local   → 127.0.0.1:3001 → vibe-mb-app (API + SPA)       │
│                                           → vibe-mb-db (Postgres)         │
│                                           → vibe-mb-redis                  │
│  Host: pt.kisaes.local   → /api/*    → 127.0.0.1:4002 → vibe-pt-backend   │
│                          → /         → 127.0.0.1:3002 → vibe-pt-frontend  │
│                                                         → vibe-pt-db       │
│  Host: <anything else>   → 302 → http://kisaes.local (catch-all)          │
│                                                                            │
└────────────────────────────────────────────────────────────────────────────┘

Port 3080 / 3081 / 3082  → IP:port fallback listeners for TB / MB / PT
                           (used by Chrome/Edge Secure DNS and Firefox DoH
                           clients that bypass the mDNS resolver)
Port 10000               → Webmin (server mgmt; UFW-restricted to LAN; PAM)
Port 9443                → Portainer (Docker UI; admin password pre-seeded)
Port 8200                → Duplicati (backups; WebUI password pre-seeded)
Port 8090                → GLM-OCR (bound to 127.0.0.1; container-to-
                           container via kisaes-net at vibe-glm-ocr:8090)

Tailscale                → Mesh VPN overlay reachable from anywhere. mDNS
                           does NOT traverse Tailscale — use Tailscale IPs
                           or split-DNS.
```

The TB client (`:3000`), MB app (`:3001`), and PT backend/frontend (`:4002` / `:3002`) are bound to `127.0.0.1` so only host nginx can reach them. This forces all LAN traffic through the hostname / IP:port listeners so CORS, cookies, and rate limits behave consistently. PT is the only app where host nginx does the `/api/*` vs `/` split itself — TB's client container and MB's app container handle that internally.

## Container map

| Container | Image | Port binding | Restart |
|---|---|---|---|
| `vibe-glm-ocr` | `ghcr.io/kisaesdevlab/vibe-glm-ocr:latest` | `127.0.0.1:8090` | always |
| `vibe-tb-db` | `postgres:16-alpine` | internal | always |
| `vibe-tb-server` | `ghcr.io/kisaesdevlab/vibe-tb-server:${IMAGE_TAG:-latest}` | internal (`:3001`) | always |
| `vibe-tb-client` | `ghcr.io/kisaesdevlab/vibe-tb-client:${IMAGE_TAG:-latest}` | `127.0.0.1:3000` | always |
| `vibe-mb-db` | `postgres:16-alpine` | internal | always |
| `vibe-mb-redis` | `redis:7-alpine` | internal | always |
| `vibe-mb-app` | `ghcr.io/kisaesdevlab/vibe-mybooks:${VIBE_MYBOOKS_TAG:-latest}` | `127.0.0.1:3001` | always |
| `vibe-pt-db` | `postgres:16-alpine` | internal | always |
| `vibe-pt-backend` | `ghcr.io/kisaesdevlab/vibept-backend:latest` | `127.0.0.1:4002` | always |
| `vibe-pt-frontend` | `ghcr.io/kisaesdevlab/vibept-frontend:latest` | `127.0.0.1:3002` | always |
| `portainer` | `portainer/portainer-ce:lts` | `0.0.0.0:9443`, `0.0.0.0:8000` | always |
| `duplicati` | `lscr.io/linuxserver/duplicati:latest` | `0.0.0.0:8200` | always |

All containers share the `kisaes-net` Docker network so they address each other by container name.

**Optional tunnel containers** (dormant unless `CLOUDFLARE_TUNNEL_TOKEN` is set in the matching `.env`):

| Container | Image | Purpose |
|---|---|---|
| `vibe-mb-cloudflared` | `cloudflare/cloudflared:latest` | CF tunnel → `vibe-mb-app:3001` |
| `vibe-pt-caddy` | `caddy:2-alpine` | Internal `/api/*` vs `/` split so the tunnel has one target |
| `vibe-pt-cloudflared` | `cloudflare/cloudflared:latest` | CF tunnel → `vibe-pt-caddy:8080` |

TB is LAN-only and has no tunnel sidecar.

## Secrets and credentials

`provision.sh` auto-generates secrets on first run and persists them under `$HOME` with `chmod 600`. Re-runs reuse existing values — secrets never rotate automatically.

| File | Contents |
|---|---|
| `~/vibe-tb/.env` | `DB_PASSWORD`, `JWT_SECRET`, `ENCRYPTION_KEY`, `ALLOWED_ORIGIN`, `APP_BASE_URL`, `IMAGE_TAG` |
| `~/vibe-mb/.env` | `POSTGRES_PASSWORD`, `JWT_SECRET`, `ENCRYPTION_KEY`, `PLAID_ENCRYPTION_KEY`, `BACKUP_ENCRYPTION_KEY`, `CORS_ORIGIN`, `TRUST_PROXY`, `VIBE_MYBOOKS_TAG`, `CLOUDFLARE_TUNNEL_TOKEN` (opt-in), `TUNNEL_ORIGIN` (opt-in) |
| `~/vibe-pt/.env` | `POSTGRES_PASSWORD`, `JWT_SECRET`, `SECRETS_ENCRYPTION_KEY`, `APPLIANCE_ID`, `CORS_ORIGIN`, `CLOUDFLARE_TUNNEL_TOKEN` (opt-in), `TUNNEL_ORIGIN` (opt-in) |
| `~/vibe-portainer/admin-password` | Portainer `admin` user password (pre-seeded; no 5-min signup lockout) |
| `~/vibe-duplicati/webui-password` | Duplicati WebUI password (prevents unauthenticated FS access on `:8200`) |
| `~/vibe-duplicati/vibe-default-backup.json` | Pre-generated Duplicati backup-job config (import via UI) |

**Back these files up separately from your database dumps.** The DBs are encrypted at rest using `ENCRYPTION_KEY` / `BACKUP_ENCRYPTION_KEY` — losing the `.env` means losing the DB, full stop.

## Post-provisioning checklist

The final phase prints this with your actual IPs substituted:

1. **Visit the landing page** (`http://kisaes.local/`) to verify mDNS works from a client device.
2. **Log in to Portainer** at `https://<ip>:9443` using `admin` and the password in `~/vibe-portainer/admin-password`. Change it if you want, but the pre-seeded one is already strong.
3. **Log in to Duplicati** at `http://<ip>:8200` using the password in `~/vibe-duplicati/webui-password`. Then Add backup → Import from a file → `~/vibe-duplicati/vibe-default-backup.json`. **Change the destination to somewhere off-box** (S3, Backblaze B2, SFTP, external disk) — the default points at `/backups/vibe-appliance` locally, which doesn't survive an SSD failure.
4. **If you want Claude-backed AI features in Vibe TB**, add `ANTHROPIC_API_KEY=sk-ant-…` to `~/vibe-tb/.env` and restart:
   ```bash
   cd ~/vibe-tb && sudo docker compose --env-file .env up -d
   ```
5. **Optional: expose MB or PT over Cloudflare Tunnel.** Create a tunnel at [one.dash.cloudflare.com](https://one.dash.cloudflare.com) → Networks → Tunnels, route it to `http://vibe-mb-app:3001` (MB) or `http://vibe-pt-caddy:8080` (PT), then edit the matching `.env`:
   ```
   CLOUDFLARE_TUNNEL_TOKEN=<paste from CF>
   TUNNEL_ORIGIN=https://<your-public-hostname>
   ```
   Re-run `./provision.sh`. The provisioner detects the token and brings up the `cloudflared` sidecar (plus a Caddy sidecar for PT), and `CORS_ORIGIN` is rewritten to the public hostname. TB does not have a tunnel sidecar — LAN only.
6. **CORS origins are single-valued.** If you need to reach the apps via a different URL than the canonical port URL / hostname (e.g. Tailscale IP, LAN IP, different HTTPS proxy), edit `ALLOWED_ORIGIN` in `~/vibe-tb/.env` or `CORS_ORIGIN` in `~/vibe-mb/.env` / `~/vibe-pt/.env` and restart the stack. When `TUNNEL_ORIGIN` is set on MB/PT, the provisioner auto-manages `CORS_ORIGIN` — don't hand-edit it there.

## Known limitations

- **GLM-OCR is not yet called by Vibe TB / Vibe MB.** The apps currently expect an Ollama-style OCR endpoint; GLM-OCR serves an OpenAI-compatible API at `/v1/chat/completions`. Wiring requires an app-side change tracked upstream.
- **CORS is single-origin per app.** Multiple origins (LAN IP + Tailscale + hostname + Cloudflare Tunnel all at once) requires either a PR to the apps' CORS parsing or an HTTPS reverse proxy in front. Tracked at [KisaesDevLab/Vibe-Trial-Balance#6](https://github.com/KisaesDevLab/Vibe-Trial-Balance/issues/6), [KisaesDevLab/Vibe-MyBooks#32](https://github.com/KisaesDevLab/Vibe-MyBooks/issues/32), and for PT in the main repo. Until then, enabling a Cloudflare Tunnel flips `CORS_ORIGIN` to the public hostname and LAN port URLs CORS-break.
- **Docker-published ports bypass UFW.** Docker's iptables rules run before UFW's `DOCKER-USER` chain on a default Ubuntu install. UFW firewalls host-level services (22/80/10000/5353) only. Ports 9443, 8200, and on-the-LAN access to 80 are reachable regardless of UFW. **Fine for a LAN appliance behind NAT; do not expose this host to the public internet without fronting it with a separate firewall or installing `ufw-docker`.**
- **Future: consolidate under a single hostname via subpaths** (`/tb/`, `/mb/`) — blocked on upstream app changes; tracked at [KisaesDevLab/Vibe-Trial-Balance#5](https://github.com/KisaesDevLab/Vibe-Trial-Balance/issues/5) and [KisaesDevLab/Vibe-MyBooks#31](https://github.com/KisaesDevLab/Vibe-MyBooks/issues/31).

## File structure

```
vibe-Linux-Setup/
├── CLAUDE.md         # Phase-by-phase reference (for human debugging and Claude Code)
├── README.md         # This file
├── bootstrap.sh      # One-line entry point: installs git, clones repo, runs provision.sh
├── provision.sh      # Idempotent 14-phase provisioner (does the actual work)
└── assets/
    └── landing.html  # Landing page source (deployed to /var/www/kisaes/)
```

## License

Proprietary — Kisaes LLC. Internal use only.
