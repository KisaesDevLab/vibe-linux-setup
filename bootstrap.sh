#!/usr/bin/env bash
# ============================================================================
# Vibe Linux Setup — Bootstrap
#
# One-liner entry point for a fresh Ubuntu Server 24.04 LTS box.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/KisaesDevLab/vibe-Linux-Setup/main/bootstrap.sh | bash
#
# What this does:
#   1. Installs git (if missing)
#   2. Clones the provisioning repo
#   3. Executes provision.sh, which does everything else:
#        - Docker + shared network
#        - GLM-OCR, Vibe TB, Vibe MB, Portainer, Duplicati
#        - Tailscale, Cockpit, Nginx landing page, UFW firewall
#        - Claude Code (for ongoing maintenance)
#
# Environment passthrough (optional):
#   TAILSCALE_AUTHKEY   pre-auth key for unattended Tailscale registration
#   TB_DB_PASSWORD      Postgres password for Vibe TB
#   MB_DB_PASSWORD      Postgres password for Vibe MB
# ============================================================================

set -euo pipefail

REPO_URL="https://github.com/KisaesDevLab/vibe-Linux-Setup.git"
INSTALL_DIR="$HOME/vibe-Linux-Setup"

echo ""
echo "╔══════════════════════════════════════════════════════╗"
echo "║          Vibe Linux Setup — Bootstrap                ║"
echo "╚══════════════════════════════════════════════════════╝"
echo ""

# ---- Step 1: Git ---------------------------------------------------------
if ! command -v git &>/dev/null; then
    echo "[1/3] Installing git..."
    sudo apt-get update -qq
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq git
else
    echo "[1/3] git already installed."
fi

# ---- Step 2: Clone repo --------------------------------------------------
if [ -d "$INSTALL_DIR/.git" ]; then
    echo "[2/3] Repo already cloned at $INSTALL_DIR — pulling latest..."
    git -C "$INSTALL_DIR" pull --ff-only
else
    echo "[2/3] Cloning provisioning repo..."
    git clone "$REPO_URL" "$INSTALL_DIR"
fi

# ---- Step 3: Hand off to provision.sh ------------------------------------
echo "[3/3] Launching provision.sh..."
echo ""

chmod +x "$INSTALL_DIR/provision.sh"
exec "$INSTALL_DIR/provision.sh" "$@"
