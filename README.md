# Vibe Linux Setup — Kisaes LLC

Automated provisioning for Ubuntu Server 24.04 LTS machines running the Kisaes application stack.

## What Gets Installed

| Service | Purpose | Access |
|---|---|---|
| **Vibe Trial Balance** | Trial balance, tax workpapers, AI classification | `http://<ip>/tb/` |
| **Vibe MyBooks** | Bookkeeping, transaction coding, client portal | `http://<ip>/mb/` |
| **GLM-OCR** | Document OCR appliance (self-contained llama.cpp + GLM-OCR GGUF) | Internal API `:8090` |
| **Landing Page** | App selector served on port 80 | `http://<ip>` |
| **Cockpit** | Web-based server & network management | `https://<ip>:9090` |
| **Portainer CE** | Docker container management UI | `https://<ip>:9443` |
| **Duplicati** | Scheduled backups | `http://<ip>:8200` |
| **Tailscale** | Mesh VPN for secure remote access | All services via `100.x.x.x` |
| **Nginx** | Reverse proxy + landing page | Port 80 |
| **UFW** | Firewall (LAN + Tailscale only) | — |

All applications run as Docker containers on a shared `kisaes-net` network.

## Quick Start

On a fresh Ubuntu Server 24.04 LTS mini PC, run:

```bash
curl -fsSL https://raw.githubusercontent.com/KisaesDevLab/vibe-Linux-Setup/main/bootstrap.sh | bash
```

That's it. `bootstrap.sh` installs git, clones this repo, and runs `provision.sh`, which executes all 14 phases end-to-end (Docker, GLM-OCR, Vibe TB, Vibe MB, Portainer, Duplicati, Tailscale, Cockpit, Nginx, UFW) and also installs Claude Code for ongoing maintenance.

The script is **idempotent** — safe to re-run if anything fails mid-way.

### Unattended mode

Pre-provide the Tailscale auth key to run with zero prompts:

```bash
curl -fsSL https://raw.githubusercontent.com/KisaesDevLab/vibe-Linux-Setup/main/bootstrap.sh \
  | TAILSCALE_AUTHKEY=tskey-auth-xxxxx bash
```

Other env vars:

- `VIBE_DOMAIN` — base hostname for the three apps (default `kisaes.lan`). The provisioner serves:
  - `http://<VIBE_DOMAIN>/` → landing page
  - `http://tb.<VIBE_DOMAIN>/` → Vibe Trial Balance
  - `http://mb.<VIBE_DOMAIN>/` → Vibe MyBooks

  You must point these three names at this box via `/etc/hosts`, router DNS, Pi-hole, or Tailscale Split DNS. The final provisioner output prints exact instructions with your actual IPs.
- `TAILSCALE_AUTHKEY` — pre-auth key for unattended Tailscale registration.

Secrets (`DB_PASSWORD`, `JWT_SECRET`, `ENCRYPTION_KEY`, `BACKUP_ENCRYPTION_KEY`) are auto-generated via `openssl rand -hex 32` and persisted to `~/vibe-tb/.env` and `~/vibe-mb/.env` (chmod 600). Re-runs of `provision.sh` keep existing values.

Flags pass through to `provision.sh`: `--skip-tailscale`, `--skip-claude`.

### Running locally after clone

```bash
cd ~/vibe-Linux-Setup
./provision.sh
```

## Requirements

- **Hardware:** Any x86_64 mini PC (tested on GMKtec NucBox M6)
- **OS:** Ubuntu Server 24.04 LTS (clean install)
- **RAM:** 8 GB minimum, 16 GB recommended
- **Storage:** 40 GB+ available
- **Network:** Internet connection (required during provisioning)
- **Claude Code (optional):** Installed by the provisioner for ongoing maintenance. Requires a Claude Pro, Max, or Console account to authenticate — the provisioner itself does not depend on it.

## Architecture

```
Port 80 (Nginx)
├── /            → Landing page (select TB or MB)
├── /tb/         → Vibe Trial Balance  (:3000)
└── /mb/         → Vibe MyBooks        (:3001)

Port 9090         → Cockpit (server management)
Port 9443         → Portainer (Docker management)
Port 8090         → GLM-OCR API (internal, OpenAI-compatible)
Port 8200         → Duplicati (backups)

Tailscale         → Mesh VPN overlay (all ports reachable remotely)
```

## Container Map

| Container | Image | Network | Restart |
|---|---|---|---|
| `vibe-glm-ocr` | `ghcr.io/kisaesdevlab/vibe-glm-ocr:latest` | kisaes-net | always |
| `vibe-tb-app` | `ghcr.io/kisaesdevlab/vibe-trial-balance:latest` | kisaes-net | always |
| `vibe-tb-db` | `postgres:16-alpine` | kisaes-net | always |
| `vibe-mb-app` | `ghcr.io/kisaesdevlab/vibe-mybooks:latest` | kisaes-net | always |
| `vibe-mb-db` | `postgres:16-alpine` | kisaes-net | always |
| `vibe-mb-redis` | `redis:7-alpine` | kisaes-net | always |
| `portainer` | `portainer/portainer-ce:lts` | kisaes-net | always |
| `duplicati` | `lscr.io/linuxserver/duplicati:latest` | kisaes-net | always |

## Post-Provisioning

After Claude Code completes all 14 phases:

1. **Change Postgres passwords** — Replace `CHANGE_ME_TB` and `CHANGE_ME_MB` in the compose files under `~/vibe-tb/` and `~/vibe-mb/`
2. **Create Portainer admin** — Visit `:9443` within 5 minutes of first startup
3. **Configure Duplicati** — Visit `:8200` and set up backup schedules
4. **React Router basename** — If using client-side routing, set `basename="/tb"` and `basename="/mb"` in each app's router config

## File Structure

```
vibe-Linux-Setup/
├── CLAUDE.md         # Phase-by-phase reference (also usable by Claude Code for debugging)
├── README.md         # This file
├── bootstrap.sh      # One-line entry point: installs git, clones repo, runs provision.sh
├── provision.sh      # Idempotent 14-phase provisioner (does the actual work)
└── assets/
    └── landing.html  # Landing page source (deployed to /var/www/kisaes/)
```

## License

Proprietary — Kisaes LLC. Internal use only.
