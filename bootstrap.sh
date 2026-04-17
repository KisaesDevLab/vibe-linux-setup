#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# Vibe Linux Setup — Bootstrap Script
# Run on a fresh Ubuntu Server 24.04 LTS to provision the full stack.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/KisaesDevLab/vibe-Linux-Setup/main/bootstrap.sh | bash
#
# What this does:
#   1. Installs git (if missing)
#   2. Installs Claude Code (native installer)
#   3. Clones this repo
#   4. Launches Claude Code inside the repo
#
# Claude Code reads CLAUDE.md automatically and provisions the entire stack:
#   Docker, Ollama + GLM-OCR, Vibe TB, Vibe MB, Portainer, Duplicati,
#   Tailscale, Cockpit, Nginx landing page, and UFW firewall.
# ============================================================================

REPO_URL="https://github.com/KisaesDevLab/vibe-Linux-Setup.git"
INSTALL_DIR="$HOME/vibe-Linux-Setup"

echo ""
echo "╔══════════════════════════════════════════════════════╗"
echo "║          Vibe Linux Setup — Bootstrap                ║"
echo "╚══════════════════════════════════════════════════════╝"
echo ""

# ---- Step 1: Git ----
if ! command -v git &>/dev/null; then
    echo "[1/3] Installing git..."
    sudo apt update -qq
    sudo apt install -y -qq git
else
    echo "[1/3] git already installed."
fi

# ---- Step 2: Claude Code ----
if ! command -v claude &>/dev/null; then
    echo "[2/3] Installing Claude Code..."
    curl -fsSL https://claude.ai/install.sh | bash

    # Ensure claude is on PATH for the current session
    export PATH="$HOME/.local/bin:$PATH"

    if ! command -v claude &>/dev/null; then
        echo ""
        echo "⚠  Claude Code installed but not found on PATH."
        echo "   Run:  source ~/.bashrc"
        echo "   Then: cd $INSTALL_DIR && claude"
        echo ""
    fi
else
    echo "[2/3] Claude Code already installed."
fi

# ---- Step 3: Clone repo ----
if [ -d "$INSTALL_DIR" ]; then
    echo "[3/3] Repo already cloned at $INSTALL_DIR — pulling latest..."
    cd "$INSTALL_DIR" && git pull --ff-only
else
    echo "[3/3] Cloning provisioning repo..."
    git clone "$REPO_URL" "$INSTALL_DIR"
    cd "$INSTALL_DIR"
fi

echo ""
echo "════════════════════════════════════════════════════════"
echo ""
echo "  Bootstrap complete. Next steps:"
echo ""
echo "  1. cd $INSTALL_DIR"
echo "  2. claude"
echo "  3. Tell Claude: \"Run the provisioning guide\""
echo ""
echo "  Claude Code will read CLAUDE.md and execute all 14"
echo "  phases to provision this mini PC."
echo ""
echo "  NOTE: You need a Claude Pro, Max, or Console account"
echo "  to authenticate Claude Code."
echo ""
echo "════════════════════════════════════════════════════════"
echo ""
