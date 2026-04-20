# Vibe Linux Setup — Kisaes LLC

Automated provisioning for Ubuntu Server 24.04 LTS machines running the Kisaes application stack. Idempotent single-shot installer — re-runnable if anything fails mid-way, and safe against re-runs once everything's up.

## What Gets Installed

| Service | Purpose | Access |
|---|---|---|
| **Vibe Trial Balance** | Trial balance, tax workpapers, AI classification | `http://tb.kisaes.local/` |
| **Vibe MyBooks** | Bookkeeping, transaction coding, client portal | `http://mb.kisaes.local/` |
| **Landing page** | Card-selector for the two apps | `http://kisaes.local/` |
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

`bootstrap.sh` installs git, clones this repo, and runs `provision.sh`, which executes the 14 phases end-to-end (base packages + Avahi, Docker, shared network, GLM-OCR, Vibe TB, Vibe MB, Portainer, Duplicati, Tailscale, Webmin, landing page, nginx, mDNS aliases, UFW, verification). It also installs Claude Code for ongoing maintenance.

The script is **idempotent** — containers, volumes, secrets, and firewall rules all no-op if they already exist, so re-running after a failure resumes cleanly.

### Unattended mode

Provide a Tailscale pre-auth key to skip the interactive browser-auth step:

```bash
curl -fsSL https://raw.githubusercontent.com/KisaesDevLab/vibe-Linux-Setup/main/bootstrap.sh \
  | TAILSCALE_AUTHKEY=tskey-auth-xxxxx bash
```

Tailscale auth has a 10-minute timeout — if no key is provided and nobody clicks the browser URL, the phase gives up and provisioning finishes. Resume later with `sudo tailscale up --ssh --accept-dns`.

### Environment overrides

- `VIBE_DOMAIN` — base hostname (default `kisaes.local`). The three services are served as:
  - `http://<VIBE_DOMAIN>/` → landing page
  - `http://tb.<VIBE_DOMAIN>/` → Vibe Trial Balance
  - `http://mb.<VIBE_DOMAIN>/` → Vibe MyBooks

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
│  Host: <anything else>   → 302 → http://kisaes.local (catch-all)          │
│                                                                            │
└────────────────────────────────────────────────────────────────────────────┘

Port 10000       → Webmin (server management; UFW-restricted to LAN; PAM auth)
Port 9443        → Portainer (Docker UI; admin password pre-seeded)
Port 8200        → Duplicati (backups; WebUI password pre-seeded)
Port 8090        → GLM-OCR (bound to 127.0.0.1; container-to-container via
                   kisaes-net at vibe-glm-ocr:8090)

Tailscale        → Mesh VPN overlay reachable from anywhere. mDNS does NOT
                   traverse Tailscale — use Tailscale IPs or split-DNS.
```

The TB client (`:3000`) and MB app (`:3001`) are bound to `127.0.0.1` so only the host nginx can reach them. This forces all LAN traffic through the hostname-based vhosts so CORS, cookies, and rate limits behave consistently.

## Container map

| Container | Image | Port binding | Restart |
|---|---|---|---|
| `vibe-glm-ocr` | `ghcr.io/kisaesdevlab/vibe-glm-ocr:latest` | `127.0.0.1:8090` | always |
| `vibe-tb-db` | `postgres:16-alpine` | internal | always |
| `vibe-tb-server` | `ghcr.io/kisaesdevlab/vibe-tb-server:latest` | internal (`:3001`) | always |
| `vibe-tb-client` | `ghcr.io/kisaesdevlab/vibe-tb-client:latest` | `127.0.0.1:3000` | always |
| `vibe-mb-db` | `postgres:16-alpine` | internal | always |
| `vibe-mb-redis` | `redis:7-alpine` | internal | always |
| `vibe-mb-app` | `ghcr.io/kisaesdevlab/vibe-mybooks:latest` | `127.0.0.1:3001` | always |
| `portainer` | `portainer/portainer-ce:lts` | `0.0.0.0:9443`, `0.0.0.0:8000` | always |
| `duplicati` | `lscr.io/linuxserver/duplicati:latest` | `0.0.0.0:8200` | always |

All containers share the `kisaes-net` Docker network so they address each other by container name.

## Secrets and credentials

`provision.sh` auto-generates secrets on first run and persists them under `$HOME` with `chmod 600`. Re-runs reuse existing values — secrets never rotate automatically.

| File | Contents |
|---|---|
| `~/vibe-tb/.env` | `DB_PASSWORD`, `JWT_SECRET`, `ENCRYPTION_KEY`, `ALLOWED_ORIGIN`, `APP_BASE_URL` |
| `~/vibe-mb/.env` | `POSTGRES_PASSWORD`, `JWT_SECRET`, `BACKUP_ENCRYPTION_KEY`, `CORS_ORIGIN` |
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
5. **CORS origins are single-valued.** If you need to reach the apps via a different URL than `tb.kisaes.local` / `mb.kisaes.local` (e.g. Tailscale IP, LAN IP, HTTPS reverse proxy), edit `ALLOWED_ORIGIN` in `~/vibe-tb/.env` or `CORS_ORIGIN` in `~/vibe-mb/.env` and restart the stack.

## Known limitations

- **GLM-OCR is not yet called by Vibe TB / Vibe MB.** The apps currently expect an Ollama-style OCR endpoint; GLM-OCR serves an OpenAI-compatible API at `/v1/chat/completions`. Wiring requires an app-side change tracked upstream.
- **CORS is single-origin per app.** Multiple origins (LAN IP + Tailscale + hostname) requires either a PR to the apps' CORS parsing or an HTTPS reverse proxy in front.
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
