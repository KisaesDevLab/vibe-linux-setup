#!/usr/bin/env bash
# ============================================================================
# Vibe Linux Setup — Provisioning Script
#
# Idempotent, single-shot provisioner for Ubuntu Server 24.04 LTS.
# Re-runnable: each phase checks current state before acting.
#
# Usage:
#   ./provision.sh                    # interactive (prompts for Tailscale auth)
#   TAILSCALE_AUTHKEY=tskey-... \
#     ./provision.sh                  # fully unattended
#   ./provision.sh --skip-tailscale   # skip Tailscale phase
#
# Environment overrides:
#   TAILSCALE_AUTHKEY   pre-auth key for unattended Tailscale registration
#   TB_DB_PASSWORD      Postgres password for Vibe TB     (default: CHANGE_ME_TB)
#   MB_DB_PASSWORD      Postgres password for Vibe MB     (default: CHANGE_ME_MB)
#   LOG_FILE            provisioning log path             (default: ~/vibe-provision.log)
# ============================================================================

set -euo pipefail

# ---- Config --------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="${LOG_FILE:-$HOME/vibe-provision.log}"
TB_DB_PASSWORD="${TB_DB_PASSWORD:-CHANGE_ME_TB}"
MB_DB_PASSWORD="${MB_DB_PASSWORD:-CHANGE_ME_MB}"
SKIP_TAILSCALE=0
SKIP_CLAUDE=0

for arg in "$@"; do
    case "$arg" in
        --skip-tailscale) SKIP_TAILSCALE=1 ;;
        --skip-claude)    SKIP_CLAUDE=1 ;;
        -h|--help)
            sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *) echo "Unknown argument: $arg" >&2; exit 2 ;;
    esac
done

# ---- Output helpers ------------------------------------------------------
if [ -t 1 ]; then
    BOLD=$'\033[1m'; CYAN=$'\033[36m'; GREEN=$'\033[32m'
    YELLOW=$'\033[33m'; RED=$'\033[31m'; RESET=$'\033[0m'
else
    BOLD=""; CYAN=""; GREEN=""; YELLOW=""; RED=""; RESET=""
fi

log()    { printf '%s[provision]%s %s\n' "$CYAN" "$RESET" "$*" | tee -a "$LOG_FILE"; }
ok()     { printf '%s  ✓%s %s\n'         "$GREEN" "$RESET" "$*" | tee -a "$LOG_FILE"; }
warn()   { printf '%s  ⚠%s %s\n'         "$YELLOW" "$RESET" "$*" | tee -a "$LOG_FILE"; }
err()    { printf '%s  ✗%s %s\n'         "$RED" "$RESET" "$*" | tee -a "$LOG_FILE" >&2; }
phase()  { printf '\n%s%s═══ %s ═══%s\n'  "$BOLD" "$CYAN" "$*" "$RESET" | tee -a "$LOG_FILE"; }

trap 'err "Provisioning aborted at line $LINENO. See $LOG_FILE"' ERR

# ---- Idempotency helpers -------------------------------------------------
container_exists()  { sudo docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "$1"; }
container_running() { sudo docker ps    --format '{{.Names}}' 2>/dev/null | grep -qx "$1"; }
network_exists()    { sudo docker network ls --format '{{.Name}}' 2>/dev/null | grep -qx "$1"; }
volume_exists()     { sudo docker volume ls   --format '{{.Name}}' 2>/dev/null | grep -qx "$1"; }

require_sudo() {
    if ! sudo -n true 2>/dev/null; then
        log "Sudo required — please enter your password (cached for the rest of the run)."
        sudo -v
    fi
    # Keep sudo alive for the duration of this script.
    while true; do sudo -n true; sleep 60; kill -0 "$$" 2>/dev/null || exit; done 2>/dev/null &
    SUDO_KEEPALIVE_PID=$!
    trap 'kill $SUDO_KEEPALIVE_PID 2>/dev/null || true' EXIT
}

# ---- Phase 1: System update + base packages ------------------------------
phase_1_base() {
    phase "PHASE 1 — System update & base packages"
    sudo apt-get update -qq
    sudo DEBIAN_FRONTEND=noninteractive apt-get upgrade -y -qq
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
        curl wget gnupg ca-certificates lsb-release software-properties-common nginx
    ok "Base packages installed ($(nginx -v 2>&1))"
}

# ---- Claude Code install (non-fatal) -------------------------------------
phase_claude_code() {
    phase "PHASE 1b — Install Claude Code"
    if [ "$SKIP_CLAUDE" -eq 1 ]; then
        warn "Skipping Claude Code install (--skip-claude)"
        return 0
    fi
    if command -v claude &>/dev/null; then
        ok "Claude Code already installed ($(claude --version 2>&1 | head -1))"
        return 0
    fi
    if curl -fsSL https://claude.ai/install.sh | bash; then
        export PATH="$HOME/.local/bin:$PATH"
        if command -v claude &>/dev/null; then
            ok "Claude Code installed at $(command -v claude)"
        else
            warn "Claude Code installed but not on PATH yet. Run: source ~/.bashrc"
        fi
    else
        warn "Claude Code install failed — non-fatal, continuing."
    fi
}

# ---- Phase 2: Docker -----------------------------------------------------
phase_2_docker() {
    phase "PHASE 2 — Docker Engine & Compose"
    if command -v docker &>/dev/null; then
        ok "Docker already installed ($(docker --version))"
    else
        sudo install -m 0755 -d /etc/apt/keyrings
        if [ ! -f /etc/apt/keyrings/docker.gpg ]; then
            curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
                | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
            sudo chmod a+r /etc/apt/keyrings/docker.gpg
        fi
        local arch codename
        arch="$(dpkg --print-architecture)"
        codename="$(. /etc/os-release && echo "$VERSION_CODENAME")"
        echo "deb [arch=${arch} signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu ${codename} stable" \
            | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
        sudo apt-get update -qq
        sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
            docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
        ok "Docker installed ($(docker --version))"
    fi

    if ! id -nG "$USER" | tr ' ' '\n' | grep -qx docker; then
        sudo usermod -aG docker "$USER"
        warn "Added $USER to docker group — log out/in to use docker without sudo."
    fi

    sudo systemctl enable docker containerd >/dev/null 2>&1 || true
    sudo systemctl start docker containerd
    ok "Docker + containerd enabled and running"
}

# ---- Phase 3: Shared network ---------------------------------------------
phase_3_network() {
    phase "PHASE 3 — Shared docker network (kisaes-net)"
    if network_exists kisaes-net; then
        ok "Network kisaes-net already exists"
    else
        sudo docker network create kisaes-net
        ok "Network kisaes-net created"
    fi
}

# ---- Phase 4: GLM-OCR ----------------------------------------------------
phase_4_glm_ocr() {
    phase "PHASE 4 — Deploy GLM-OCR"
    if container_running vibe-glm-ocr; then
        ok "vibe-glm-ocr already running"
    else
        container_exists vibe-glm-ocr && sudo docker rm -f vibe-glm-ocr >/dev/null
        sudo docker run -d \
            --name vibe-glm-ocr \
            --restart=always \
            --network kisaes-net \
            -p 8090:8090 \
            --log-driver json-file \
            --log-opt max-size=50m \
            --log-opt max-file=5 \
            ghcr.io/kisaesdevlab/vibe-glm-ocr:latest >/dev/null
        ok "vibe-glm-ocr container started"
    fi
    log "Waiting for /health to come up (up to 60s)..."
    local i
    for i in $(seq 1 30); do
        if curl -fsS http://localhost:8090/health >/dev/null 2>&1; then
            ok "GLM-OCR healthy"
            return 0
        fi
        sleep 2
    done
    err "GLM-OCR did not become healthy in 60s. Recent logs:"
    sudo docker logs --tail 50 vibe-glm-ocr 2>&1 | sed 's/^/    /' | tee -a "$LOG_FILE"
    return 1
}

# ---- Phase 5: Vibe Trial Balance -----------------------------------------
phase_5_tb() {
    phase "PHASE 5 — Deploy Vibe Trial Balance"
    mkdir -p "$HOME/vibe-tb"
    cat > "$HOME/vibe-tb/docker-compose.yml" <<EOF
services:
  vibe-tb-db:
    image: postgres:16-alpine
    container_name: vibe-tb-db
    restart: always
    environment:
      POSTGRES_USER: vibedb
      POSTGRES_PASSWORD: ${TB_DB_PASSWORD}
      POSTGRES_DB: vibe_tb
    volumes:
      - vibe_tb_pgdata:/var/lib/postgresql/data
    networks:
      - kisaes-net

  vibe-tb-app:
    image: ghcr.io/kisaesdevlab/vibe-trial-balance:latest
    container_name: vibe-tb-app
    restart: always
    depends_on:
      - vibe-tb-db
    environment:
      DATABASE_URL: postgres://vibedb:${TB_DB_PASSWORD}@vibe-tb-db:5432/vibe_tb
      NODE_ENV: production
    ports:
      - "3000:3000"
    networks:
      - kisaes-net

volumes:
  vibe_tb_pgdata:

networks:
  kisaes-net:
    external: true
EOF
    (cd "$HOME/vibe-tb" && sudo docker compose up -d)
    ok "Vibe TB stack up"
}

# ---- Phase 6: Vibe MyBooks -----------------------------------------------
phase_6_mb() {
    phase "PHASE 6 — Deploy Vibe MyBooks"
    mkdir -p "$HOME/vibe-mb"
    cat > "$HOME/vibe-mb/docker-compose.yml" <<EOF
services:
  vibe-mb-db:
    image: postgres:16-alpine
    container_name: vibe-mb-db
    restart: always
    environment:
      POSTGRES_USER: vibedb
      POSTGRES_PASSWORD: ${MB_DB_PASSWORD}
      POSTGRES_DB: vibe_mb
    volumes:
      - vibe_mb_pgdata:/var/lib/postgresql/data
    networks:
      - kisaes-net

  vibe-mb-redis:
    image: redis:7-alpine
    container_name: vibe-mb-redis
    restart: always
    networks:
      - kisaes-net

  vibe-mb-app:
    image: ghcr.io/kisaesdevlab/vibe-mybooks:latest
    container_name: vibe-mb-app
    restart: always
    depends_on:
      - vibe-mb-db
      - vibe-mb-redis
    environment:
      DATABASE_URL: postgres://vibedb:${MB_DB_PASSWORD}@vibe-mb-db:5432/vibe_mb
      REDIS_URL: redis://vibe-mb-redis:6379
      NODE_ENV: production
    ports:
      - "3001:3000"
    networks:
      - kisaes-net

volumes:
  vibe_mb_pgdata:

networks:
  kisaes-net:
    external: true
EOF
    (cd "$HOME/vibe-mb" && sudo docker compose up -d)
    ok "Vibe MB stack up"
}

# ---- Phase 7: Portainer --------------------------------------------------
phase_7_portainer() {
    phase "PHASE 7 — Deploy Portainer CE"
    volume_exists portainer_data || sudo docker volume create portainer_data >/dev/null
    if container_running portainer; then
        ok "Portainer already running"
        return
    fi
    container_exists portainer && sudo docker rm -f portainer >/dev/null
    sudo docker run -d \
        --name portainer \
        --restart=always \
        --network kisaes-net \
        -p 8000:8000 \
        -p 9443:9443 \
        -v /var/run/docker.sock:/var/run/docker.sock \
        -v portainer_data:/data \
        portainer/portainer-ce:lts >/dev/null
    ok "Portainer started — finish setup at https://<host>:9443 within 5 minutes"
}

# ---- Phase 8: Duplicati --------------------------------------------------
phase_8_duplicati() {
    phase "PHASE 8 — Deploy Duplicati Backup"
    if container_running duplicati; then
        ok "Duplicati already running"
        return
    fi
    container_exists duplicati && sudo docker rm -f duplicati >/dev/null
    sudo docker run -d \
        --name duplicati \
        --restart=always \
        --network kisaes-net \
        -p 8200:8200 \
        -v duplicati_config:/data \
        -v /:/source:ro \
        lscr.io/linuxserver/duplicati:latest >/dev/null
    ok "Duplicati started — configure backups at http://<host>:8200"
}

# ---- Phase 9: Tailscale --------------------------------------------------
phase_9_tailscale() {
    phase "PHASE 9 — Install & configure Tailscale"
    if [ "$SKIP_TAILSCALE" -eq 1 ]; then
        warn "Skipping Tailscale phase (--skip-tailscale)"
        return 0
    fi
    if ! command -v tailscale &>/dev/null; then
        curl -fsSL https://tailscale.com/install.sh | sh
    else
        ok "Tailscale already installed ($(tailscale version | head -1))"
    fi
    sudo systemctl enable --now tailscaled >/dev/null 2>&1 || true

    if tailscale status >/dev/null 2>&1 && tailscale ip -4 >/dev/null 2>&1; then
        ok "Tailscale already authenticated: $(tailscale ip -4 | head -1)"
        return 0
    fi

    if [ -n "${TAILSCALE_AUTHKEY:-}" ]; then
        log "Bringing Tailscale up with provided auth key (unattended)..."
        sudo tailscale up --ssh --accept-dns --auth-key="$TAILSCALE_AUTHKEY"
    else
        warn "Tailscale needs interactive auth."
        warn "The next command will print a URL. Open it in a browser to register this node."
        warn "The script will resume automatically once auth completes."
        sudo tailscale up --ssh --accept-dns
    fi
    ok "Tailscale up: $(tailscale ip -4 | head -1)"
}

# ---- Phase 10: Cockpit ---------------------------------------------------
phase_10_cockpit() {
    phase "PHASE 10 — Install Cockpit"
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
        cockpit cockpit-networkmanager cockpit-storaged cockpit-packagekit
    sudo systemctl enable --now cockpit.socket >/dev/null 2>&1
    ok "Cockpit listening on https://<host>:9090"
}

# ---- Phase 11: Landing page ----------------------------------------------
phase_11_landing() {
    phase "PHASE 11 — Deploy landing page"
    local src="$SCRIPT_DIR/assets/landing.html"
    if [ ! -f "$src" ]; then
        err "Landing page source not found at $src"
        return 1
    fi
    sudo mkdir -p /var/www/kisaes
    sudo cp "$src" /var/www/kisaes/index.html
    ok "Landing page deployed to /var/www/kisaes/index.html"
}

# ---- Phase 12: Nginx reverse proxy ---------------------------------------
phase_12_nginx() {
    phase "PHASE 12 — Configure Nginx reverse proxy"
    sudo rm -f /etc/nginx/sites-enabled/default
    sudo tee /etc/nginx/sites-available/kisaes > /dev/null <<'EOF'
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name _;

    root /var/www/kisaes;
    index index.html;

    location = / {
        try_files /index.html =404;
    }

    location ~* \.(css|js|png|jpg|svg|ico|woff2?)$ {
        root /var/www/kisaes;
        expires 7d;
    }

    location /tb/ {
        proxy_pass http://127.0.0.1:3000/;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_read_timeout 300s;
        proxy_send_timeout 300s;
    }

    location /mb/ {
        proxy_pass http://127.0.0.1:3001/;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_read_timeout 300s;
        proxy_send_timeout 300s;
    }
}
EOF
    sudo ln -sf /etc/nginx/sites-available/kisaes /etc/nginx/sites-enabled/kisaes
    sudo nginx -t
    sudo systemctl restart nginx
    sudo systemctl enable nginx >/dev/null 2>&1
    ok "Nginx reverse proxy live"
}

# ---- Phase 13: UFW -------------------------------------------------------
phase_13_ufw() {
    phase "PHASE 13 — Configure UFW firewall"
    sudo ufw --force default deny incoming >/dev/null
    sudo ufw --force default allow outgoing >/dev/null
    sudo ufw allow from 192.168.0.0/16 to any port 22   >/dev/null || true
    sudo ufw allow from 192.168.0.0/16 to any port 80   >/dev/null || true
    sudo ufw allow from 192.168.0.0/16 to any port 9090 >/dev/null || true
    sudo ufw --force enable >/dev/null
    ok "UFW active (LAN-only on 22/80/9090)"
}

# ---- Phase 14: Final verification ----------------------------------------
phase_14_verify() {
    phase "PHASE 14 — Final verification"
    local fail=0

    log "Containers:"
    sudo docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" \
        | sed 's/^/    /' | tee -a "$LOG_FILE"

    if curl -fsS http://localhost:8090/health >/dev/null 2>&1; then
        ok "GLM-OCR /health OK"
    else
        err "GLM-OCR /health FAILED"; fail=1
    fi

    local code
    code="$(curl -s -o /dev/null -w '%{http_code}' http://localhost/)"
    if [ "$code" = "200" ]; then
        ok "Landing page HTTP 200"
    else
        err "Landing page returned HTTP $code"; fail=1
    fi

    if [ "$SKIP_TAILSCALE" -eq 0 ] && command -v tailscale &>/dev/null; then
        local ts_ip
        ts_ip="$(tailscale ip -4 2>/dev/null | head -1 || true)"
        if [ -n "$ts_ip" ]; then
            ok "Tailscale IP: $ts_ip"
        else
            warn "Tailscale not yet authenticated"
        fi
    fi

    log "Boot-time enabled services:"
    for svc in docker containerd tailscaled cockpit.socket nginx; do
        local state
        state="$(sudo systemctl is-enabled "$svc" 2>/dev/null || echo missing)"
        printf '    %-20s %s\n' "$svc" "$state" | tee -a "$LOG_FILE"
    done

    if [ "$fail" -eq 0 ]; then
        ok "All verification checks passed"
    else
        err "Some verification checks failed — see $LOG_FILE"
        return 1
    fi
}

# ---- Main ----------------------------------------------------------------
main() {
    : > "$LOG_FILE"
    printf '%s%s\n  Vibe Linux Setup — Provisioning\n  Log: %s\n%s\n' \
        "$BOLD" "$CYAN" "$LOG_FILE" "$RESET"

    require_sudo
    phase_1_base
    phase_claude_code
    phase_2_docker
    phase_3_network
    phase_4_glm_ocr
    phase_5_tb
    phase_6_mb
    phase_7_portainer
    phase_8_duplicati
    phase_9_tailscale
    phase_10_cockpit
    phase_11_landing
    phase_12_nginx
    phase_13_ufw
    phase_14_verify

    echo ""
    printf '%s%sProvisioning complete.%s\n' "$GREEN" "$BOLD" "$RESET"
    echo ""
    echo "Next steps:"
    echo "  • Visit http://<host>/         — landing page"
    echo "  • Visit https://<host>:9443    — Portainer (create admin within 5 min)"
    echo "  • Visit http://<host>:8200     — Duplicati (configure backups)"
    echo "  • Change Postgres passwords in ~/vibe-tb/ and ~/vibe-mb/ before production use"
    if command -v claude &>/dev/null; then
        echo "  • Run 'claude' from this directory for ongoing maintenance help"
    fi
    echo ""
}

main "$@"
