# Vibe Linux Setup — Kisaes LLC

Automated provisioning for Ubuntu Server 24.04 LTS machines running the Kisaes application stack.

## What Gets Installed

| Service | Purpose | Access |
|---|---|---|
| **Vibe Trial Balance** | Trial balance, tax workpapers, AI classification | `http://<ip>/tb/` |
| **Vibe MyBooks** | Bookkeeping, transaction coding, client portal | `http://<ip>/mb/` |
| **GLM-OCR (Ollama)** | Document OCR for scanned financials | Internal API `:11434` |
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

This installs git, Claude Code, and clones this repo. Then:

```bash
cd ~/vibe-Linux-Setup
claude
```

Tell Claude Code: **"Run the provisioning guide"**

Claude Code reads `CLAUDE.md` and executes all 14 phases automatically, verifying each step before moving on.

## Requirements

- **Hardware:** Any x86_64 mini PC (tested on GMKtec NucBox M6)
- **OS:** Ubuntu Server 24.04 LTS (clean install)
- **RAM:** 8 GB minimum, 16 GB recommended
- **Storage:** 40 GB+ available
- **Network:** Internet connection (required during provisioning)
- **Claude Code:** Requires a Claude Pro ($20/mo), Max, or Console account

## Architecture

```
Port 80 (Nginx)
├── /            → Landing page (select TB or MB)
├── /tb/         → Vibe Trial Balance  (:3000)
└── /mb/         → Vibe MyBooks        (:3001)

Port 9090         → Cockpit (server management)
Port 9443         → Portainer (Docker management)
Port 11434        → Ollama / GLM-OCR API (internal)
Port 8200         → Duplicati (backups)

Tailscale         → Mesh VPN overlay (all ports reachable remotely)
```

## Container Map

| Container | Image | Network | Restart |
|---|---|---|---|
| `ollama` | `ollama/ollama:latest` | kisaes-net | always |
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
├── CLAUDE.md         # Phase-by-phase provisioning instructions (read by Claude Code)
├── README.md         # This file
├── bootstrap.sh      # One-line entry point for fresh boxes
└── assets/
    └── landing.html  # Landing page source (deployed to /var/www/kisaes/)
```

## License

Proprietary — Kisaes LLC. Internal use only.
