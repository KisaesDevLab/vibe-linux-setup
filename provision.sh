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
#   VIBE_DOMAIN         base hostname for the three apps   (default: kisaes.lan)
#                         landing → http://<VIBE_DOMAIN>/
#                         TB      → http://tb.<VIBE_DOMAIN>/
#                         MB      → http://mb.<VIBE_DOMAIN>/
#   TAILSCALE_AUTHKEY   pre-auth key for unattended Tailscale registration
#   LOG_FILE            provisioning log path              (default: ~/vibe-provision.log)
#
# Secrets (DB_PASSWORD, JWT_SECRET, ENCRYPTION_KEY, BACKUP_ENCRYPTION_KEY) are
# auto-generated once per host via `openssl rand -hex 32` and persisted to
# ~/vibe-tb/.env and ~/vibe-mb/.env (chmod 600). Re-runs keep existing values.
# ============================================================================

set -euo pipefail

# ---- Config --------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="${LOG_FILE:-$HOME/vibe-provision.log}"
VIBE_DOMAIN="${VIBE_DOMAIN:-kisaes.lan}"
TB_URL="http://tb.${VIBE_DOMAIN}"
MB_URL="http://mb.${VIBE_DOMAIN}"
LANDING_URL="http://${VIBE_DOMAIN}"
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

# ensure_env FILE KEY [VALUE]
#   Sets KEY=VALUE in FILE only if KEY is not already present with a non-empty
#   value. If VALUE is omitted, generates a 32-byte hex secret via openssl.
#   File is chmod 600. Idempotent — safe across re-runs, secrets never rotate.
ensure_env() {
    local file="$1" key="$2"
    local value="${3-}"
    touch "$file"
    chmod 600 "$file"
    if grep -qE "^${key}=..*\$" "$file"; then
        return 0
    fi
    # Drop any prior empty-valued line for this key
    if grep -qE "^${key}=\$" "$file"; then
        sudo sed -i "/^${key}=\$/d" "$file" 2>/dev/null || \
            { grep -v "^${key}=\$" "$file" > "${file}.tmp" && mv "${file}.tmp" "$file"; }
    fi
    if [ -z "$value" ]; then
        value="$(openssl rand -hex 32)"
    fi
    printf '%s=%s\n' "$key" "$value" >> "$file"
}

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

# ---- Phase 5: Vibe Trial Balance (split: db + server + client) -----------
phase_5_tb() {
    phase "PHASE 5 — Deploy Vibe Trial Balance"
    mkdir -p "$HOME/vibe-tb"
    local env_file="$HOME/vibe-tb/.env"

    # Idempotent secrets + config. Re-runs keep existing values.
    ensure_env "$env_file" DB_PASSWORD
    ensure_env "$env_file" JWT_SECRET
    ensure_env "$env_file" ENCRYPTION_KEY
    ensure_env "$env_file" ALLOWED_ORIGIN "$TB_URL"
    ensure_env "$env_file" APP_BASE_URL   "$TB_URL"

    cat > "$HOME/vibe-tb/docker-compose.yml" <<'EOF'
# Auto-generated by provision.sh. Edit .env for secrets; re-run provision.sh
# (safe — idempotent) to regenerate this file.
services:
  db:
    image: postgres:16-alpine
    container_name: vibe-tb-db
    restart: always
    environment:
      POSTGRES_USER: vibetb
      POSTGRES_PASSWORD: ${DB_PASSWORD}
      POSTGRES_DB: vibe_tb_db
    volumes:
      - pgdata:/var/lib/postgresql/data
    networks: [kisaes-net]
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U vibetb -d vibe_tb_db"]
      interval: 10s
      timeout: 5s
      retries: 5

  server:
    image: ghcr.io/kisaesdevlab/vibe-tb-server:latest
    container_name: vibe-tb-server
    pull_policy: always
    restart: always
    depends_on:
      db:
        condition: service_healthy
    environment:
      NODE_ENV: production
      PORT: 3001
      DB_HOST: vibe-tb-db
      DB_PORT: 5432
      DB_NAME: vibe_tb_db
      DB_USER: vibetb
      DB_PASSWORD: ${DB_PASSWORD}
      JWT_SECRET: ${JWT_SECRET}
      ENCRYPTION_KEY: ${ENCRYPTION_KEY}
      ALLOWED_ORIGIN: ${ALLOWED_ORIGIN}
      APP_BASE_URL: ${APP_BASE_URL}
      NODE_OPTIONS: --max-old-space-size=1024
    volumes:
      - uploads:/app/server/uploads
      - backups:/app/server/backups
    expose: ["3001"]
    networks: [kisaes-net]
    healthcheck:
      test: ["CMD-SHELL", "node -e \"require('http').get('http://localhost:3001/api/v1/health', r => process.exit(r.statusCode===200?0:1)).on('error', () => process.exit(1))\""]
      interval: 30s
      timeout: 5s
      retries: 5
      start_period: 30s

  client:
    image: ghcr.io/kisaesdevlab/vibe-tb-client:latest
    container_name: vibe-tb-client
    pull_policy: always
    restart: always
    depends_on:
      server:
        condition: service_healthy
    # Host port 3000 → client's internal nginx on 80. Host nginx then proxies
    # tb.<VIBE_DOMAIN> here. Not published on 80 directly so host nginx owns
    # that port for hostname-based routing across all three apps.
    ports:
      - "3000:80"
    networks: [kisaes-net]

volumes:
  pgdata:
  uploads:
  backups:

networks:
  kisaes-net:
    external: true
EOF
    (cd "$HOME/vibe-tb" && sudo docker compose --env-file .env pull --quiet)
    (cd "$HOME/vibe-tb" && sudo docker compose --env-file .env up -d)
    ok "Vibe TB stack up — will serve at ${TB_URL}"
}

# ---- Phase 6: Vibe MyBooks (app + db + redis) ----------------------------
phase_6_mb() {
    phase "PHASE 6 — Deploy Vibe MyBooks"
    mkdir -p "$HOME/vibe-mb/data"
    local env_file="$HOME/vibe-mb/.env"

    ensure_env "$env_file" POSTGRES_PASSWORD
    ensure_env "$env_file" JWT_SECRET
    ensure_env "$env_file" BACKUP_ENCRYPTION_KEY
    ensure_env "$env_file" CORS_ORIGIN "$MB_URL"

    cat > "$HOME/vibe-mb/docker-compose.yml" <<'EOF'
# Auto-generated by provision.sh. Edit .env for secrets; re-run provision.sh
# (safe — idempotent) to regenerate this file.
services:
  db:
    image: postgres:16-alpine
    container_name: vibe-mb-db
    restart: always
    environment:
      POSTGRES_USER: kisbooks
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
      POSTGRES_DB: kisbooks
    volumes:
      - pgdata:/var/lib/postgresql/data
    networks: [kisaes-net]
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U kisbooks"]
      interval: 5s
      timeout: 5s
      retries: 5

  redis:
    image: redis:7-alpine
    container_name: vibe-mb-redis
    restart: always
    volumes:
      - redis-data:/data
    networks: [kisaes-net]
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 5s
      timeout: 5s
      retries: 5

  app:
    image: ghcr.io/kisaesdevlab/vibe-mybooks:latest
    container_name: vibe-mb-app
    pull_policy: always
    restart: always
    depends_on:
      db:
        condition: service_healthy
      redis:
        condition: service_healthy
    environment:
      NODE_ENV: production
      PORT: 3001
      DATABASE_URL: postgresql://kisbooks:${POSTGRES_PASSWORD}@vibe-mb-db:5432/kisbooks
      REDIS_URL: redis://vibe-mb-redis:6379
      JWT_SECRET: ${JWT_SECRET}
      BACKUP_ENCRYPTION_KEY: ${BACKUP_ENCRYPTION_KEY}
      CORS_ORIGIN: ${CORS_ORIGIN}
      UPLOAD_DIR: /data/uploads
      BACKUP_DIR: /data/backups
    volumes:
      - ./data:/data
    ports:
      - "3001:3001"
    networks: [kisaes-net]

volumes:
  pgdata:
  redis-data:

networks:
  kisaes-net:
    external: true
EOF
    (cd "$HOME/vibe-mb" && sudo docker compose --env-file .env pull --quiet)
    (cd "$HOME/vibe-mb" && sudo docker compose --env-file .env up -d)
    ok "Vibe MB stack up — will serve at ${MB_URL}"
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
    # Substitute {{TB_URL}} / {{MB_URL}} placeholders with the resolved hostnames.
    sed -e "s|{{TB_URL}}|${TB_URL}|g" \
        -e "s|{{MB_URL}}|${MB_URL}|g" \
        "$src" | sudo tee /var/www/kisaes/index.html >/dev/null
    ok "Landing page deployed (links: ${TB_URL}, ${MB_URL})"
}

# ---- Phase 12: Nginx reverse proxy (hostname-based) ----------------------
phase_12_nginx() {
    phase "PHASE 12 — Configure Nginx reverse proxy (hostname routing)"
    sudo rm -f /etc/nginx/sites-enabled/default

    # Note: unquoted heredoc so ${VIBE_DOMAIN} expands; escape nginx variables with \$.
    sudo tee /etc/nginx/sites-available/kisaes > /dev/null <<EOF
# Landing page — http://${VIBE_DOMAIN}
server {
    listen 80;
    listen [::]:80;
    server_name ${VIBE_DOMAIN};

    root /var/www/kisaes;
    index index.html;

    location / {
        try_files \$uri \$uri/ =404;
    }

    location ~* \\.(css|js|png|jpg|svg|ico|woff2?)\$ {
        root /var/www/kisaes;
        expires 7d;
    }
}

# Vibe Trial Balance — http://tb.${VIBE_DOMAIN}
server {
    listen 80;
    listen [::]:80;
    server_name tb.${VIBE_DOMAIN};

    client_max_body_size 50m;

    location / {
        proxy_pass http://127.0.0.1:3000;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_read_timeout 300s;
        proxy_send_timeout 300s;
    }
}

# Vibe MyBooks — http://mb.${VIBE_DOMAIN}
server {
    listen 80;
    listen [::]:80;
    server_name mb.${VIBE_DOMAIN};

    client_max_body_size 50m;

    location / {
        proxy_pass http://127.0.0.1:3001;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_read_timeout 300s;
        proxy_send_timeout 300s;
    }
}

# Catch-all: unknown Host → 302 to landing page
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name _;
    return 302 http://${VIBE_DOMAIN}\$request_uri;
}
EOF
    sudo ln -sf /etc/nginx/sites-available/kisaes /etc/nginx/sites-enabled/kisaes
    sudo nginx -t
    sudo systemctl restart nginx
    sudo systemctl enable nginx >/dev/null 2>&1
    ok "Nginx reverse proxy live on ${VIBE_DOMAIN}, tb.${VIBE_DOMAIN}, mb.${VIBE_DOMAIN}"
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
    code="$(curl -s -o /dev/null -w '%{http_code}' -H "Host: ${VIBE_DOMAIN}" http://localhost/)"
    if [ "$code" = "200" ]; then
        ok "Landing vhost (${VIBE_DOMAIN}) → HTTP 200"
    else
        err "Landing vhost returned HTTP $code"; fail=1
    fi

    code="$(curl -s -o /dev/null -w '%{http_code}' -H "Host: tb.${VIBE_DOMAIN}" http://localhost/)"
    if [ "$code" = "200" ] || [ "$code" = "302" ]; then
        ok "TB vhost (tb.${VIBE_DOMAIN}) → HTTP $code"
    else
        warn "TB vhost returned HTTP $code (may still be warming up)"
    fi

    code="$(curl -s -o /dev/null -w '%{http_code}' -H "Host: mb.${VIBE_DOMAIN}" http://localhost/)"
    if [ "$code" = "200" ] || [ "$code" = "302" ] || [ "$code" = "404" ]; then
        ok "MB vhost (mb.${VIBE_DOMAIN}) → HTTP $code"
    else
        warn "MB vhost returned HTTP $code (may still be warming up)"
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

    local lan_ip ts_ip=""
    lan_ip="$(hostname -I 2>/dev/null | awk '{print $1}' || true)"
    if command -v tailscale &>/dev/null; then
        ts_ip="$(tailscale ip -4 2>/dev/null | head -1 || true)"
    fi

    echo "${BOLD}DNS setup required${RESET} — the three apps resolve by hostname, not IP."
    echo "Point these three names at this box (pick ONE approach):"
    echo ""
    echo "  ${VIBE_DOMAIN}"
    echo "  tb.${VIBE_DOMAIN}"
    echo "  mb.${VIBE_DOMAIN}"
    echo ""
    echo "${BOLD}Option A — /etc/hosts on each client machine${RESET}"
    if [ -n "$lan_ip" ]; then
        echo "    $lan_ip  ${VIBE_DOMAIN} tb.${VIBE_DOMAIN} mb.${VIBE_DOMAIN}"
    fi
    if [ -n "$ts_ip" ]; then
        echo "    $ts_ip  ${VIBE_DOMAIN} tb.${VIBE_DOMAIN} mb.${VIBE_DOMAIN}    # via Tailscale"
    fi
    echo ""
    echo "${BOLD}Option B — Tailscale split DNS${RESET} (admin console)"
    echo "    Machines → DNS → Split DNS → add '${VIBE_DOMAIN}' pointing to ${ts_ip:-<this-tailscale-ip>}"
    echo ""
    echo "${BOLD}Option C — router / Pi-hole${RESET}"
    echo "    Add three A records for the names above → ${lan_ip:-<this-lan-ip>}"
    echo ""
    echo "${BOLD}Then visit:${RESET}"
    echo "  • ${LANDING_URL}/         — landing page"
    echo "  • ${TB_URL}/              — Vibe Trial Balance"
    echo "  • ${MB_URL}/              — Vibe MyBooks"
    echo "  • https://${lan_ip:-<host>}:9443  — Portainer (create admin within 5 min)"
    echo "  • http://${lan_ip:-<host>}:8200   — Duplicati (configure backups)"
    echo ""
    echo "${BOLD}Secrets:${RESET} auto-generated and stored in:"
    echo "  • ~/vibe-tb/.env  (DB_PASSWORD, JWT_SECRET, ENCRYPTION_KEY, ALLOWED_ORIGIN)"
    echo "  • ~/vibe-mb/.env  (POSTGRES_PASSWORD, JWT_SECRET, BACKUP_ENCRYPTION_KEY, CORS_ORIGIN)"
    echo ""
    if command -v claude &>/dev/null; then
        echo "Run 'claude' from this directory for ongoing maintenance help."
        echo ""
    fi
}

main "$@"
