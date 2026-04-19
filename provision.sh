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
#   VIBE_DOMAIN         base hostname for the three apps   (default: kisaes.local)
#                         landing → http://<VIBE_DOMAIN>/
#                         TB      → http://tb.<VIBE_DOMAIN>/
#                         MB      → http://mb.<VIBE_DOMAIN>/
#                         Default is a .local (mDNS) domain — zero client-side
#                         DNS config required on modern macOS / Linux / Win10+.
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
VIBE_DOMAIN="${VIBE_DOMAIN:-kisaes.local}"

# LAN IP detection. RFC1918 only — skips Tailscale CGNAT (100.64/10) and
# link-local (169.254/16). The apps' CORS allow-list is a single origin so
# we bake this IP into ALLOWED_ORIGIN / APP_BASE_URL / CORS_ORIGIN below.
# Override with LAN_IP=... on re-run if DHCP shuffles the address.
LAN_IP="${LAN_IP:-$(ip -4 -o addr show scope global 2>/dev/null \
    | awk '{print $4}' | cut -d/ -f1 \
    | grep -E '^(10\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[01])\.)' \
    | head -1)}"
if [ -z "$LAN_IP" ]; then
    echo "ERROR: could not detect a LAN IPv4 (RFC1918). Set LAN_IP=... in env." >&2
    exit 1
fi

# TB_URL / MB_URL are the *canonical* origins the apps advertise — they become
# ALLOWED_ORIGIN (TB) and CORS_ORIGIN (MB), and APP_BASE_URL (TB). Port-based
# rather than hostname-based because the hostname URL (tb.kisaes.local) fails
# for Windows clients running Chrome/Edge Secure DNS or Firefox DoH, which
# bypass the mDNS resolver. Port URLs work on every client that can reach the
# LAN IP. The landing page links to these.
TB_URL="http://${LAN_IP}:3080"
MB_URL="http://${LAN_IP}:3081"
# LANDING_URL is still served by hostname routing — it's static HTML with no
# CORS, so mDNS resolution is the only requirement and it works on most
# clients. Fallback: http://<lan-ip>/ also serves the landing via the
# default_server catch-all.
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

# set_env FILE KEY VALUE
#   Always writes KEY=VALUE, overwriting any existing value. Use for env vars
#   that must track VIBE_DOMAIN / LAN_IP changes on re-run (origin URLs,
#   base URLs) — unlike ensure_env, which keeps existing values (correct for
#   secrets). Safe to call repeatedly; docker compose picks up env changes
#   on the next `up -d` and recreates the container.
set_env() {
    local file="$1" key="$2" value="$3"
    touch "$file"
    chmod 600 "$file"
    if grep -qE "^${key}=" "$file"; then
        # `|` delimiter avoids collisions with URL slashes in the value.
        local tmp="${file}.tmp"
        awk -v k="$key" -v v="$value" '
            $0 ~ "^" k "=" { print k "=" v; next }
            { print }
        ' "$file" > "$tmp" && mv "$tmp" "$file"
        chmod 600 "$file"
    else
        printf '%s=%s\n' "$key" "$value" >> "$file"
    fi
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
        curl wget gnupg ca-certificates lsb-release software-properties-common nginx \
        avahi-daemon avahi-utils apache2-utils
    sudo systemctl enable --now avahi-daemon >/dev/null 2>&1 || true
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
        # Bound to 127.0.0.1 — only the host (curl / nginx) and other containers
        # on kisaes-net (via container name `vibe-glm-ocr:8090`) reach it. Not
        # exposed to the LAN because no browser-facing consumer needs it.
        sudo docker run -d \
            --name vibe-glm-ocr \
            --restart=always \
            --network kisaes-net \
            -p 127.0.0.1:8090:8090 \
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
    # URL-type vars use set_env (always overwrites) so a DHCP-shuffled LAN_IP
    # or a VIBE_DOMAIN change is applied on re-run. Secrets stay with
    # ensure_env (never rotate automatically).
    set_env "$env_file" ALLOWED_ORIGIN "$TB_URL"
    set_env "$env_file" APP_BASE_URL   "$TB_URL"

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
    # Bound to 127.0.0.1 — the only consumer is host nginx (proxying
    # tb.<VIBE_DOMAIN> → 127.0.0.1:3000). Binding to all interfaces would
    # let a LAN client hit http://<host>:3000 directly, bypassing nginx
    # and confusing the app's CORS check (Origin=http://<ip>:3000 vs the
    # configured ALLOWED_ORIGIN=http://tb.<VIBE_DOMAIN>).
    ports:
      - "127.0.0.1:3000:80"
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
    # Required by the vibe-mybooks image's in-container bootstrap. Without
    # either, the app aborts on startup with "missing required environment
    # variables" and the container crash-loops. Per the upstream .env.example.
    ensure_env "$env_file" ENCRYPTION_KEY
    ensure_env "$env_file" PLAID_ENCRYPTION_KEY
    # set_env (always overwrites) so LAN_IP / VIBE_DOMAIN changes on re-run
    # propagate to the container.
    set_env "$env_file" CORS_ORIGIN "$MB_URL"

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
      ENCRYPTION_KEY: ${ENCRYPTION_KEY}
      PLAID_ENCRYPTION_KEY: ${PLAID_ENCRYPTION_KEY}
      CORS_ORIGIN: ${CORS_ORIGIN}
      UPLOAD_DIR: /data/uploads
      BACKUP_DIR: /data/backups
    volumes:
      - ./data:/data
    # Bound to 127.0.0.1 — host nginx proxies mb.<VIBE_DOMAIN> →
    # 127.0.0.1:3001. LAN clients must go through nginx so CORS lines up.
    ports:
      - "127.0.0.1:3001:3001"
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
# Pre-seeds the admin account so the 5-minute signup lockout never fires.
# Plaintext is persisted to ~/vibe-portainer/admin-password (chmod 600) so
# re-runs reuse the same credential instead of generating a new one each time.
phase_7_portainer() {
    phase "PHASE 7 — Deploy Portainer CE"
    volume_exists portainer_data || sudo docker volume create portainer_data >/dev/null

    mkdir -p "$HOME/vibe-portainer"
    local pw_file="$HOME/vibe-portainer/admin-password"
    touch "$pw_file"
    chmod 600 "$pw_file"

    local admin_pw admin_hash
    if [ -s "$pw_file" ]; then
        admin_pw="$(cat "$pw_file")"
    else
        admin_pw="$(openssl rand -base64 32 | tr -d '=+/' | head -c 24)"
        printf '%s\n' "$admin_pw" > "$pw_file"
        chmod 600 "$pw_file"
    fi

    # htpasswd ships with apache2-utils (installed in phase 1). -B = bcrypt.
    # The hash contains `$` signs — `--admin-password` takes the hash directly;
    # double-quoting expands the shell var but leaves the hash intact.
    admin_hash="$(htpasswd -nbB admin "$admin_pw" | cut -d: -f2)"

    if container_running portainer; then
        ok "Portainer already running (credentials in $pw_file)"
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
        portainer/portainer-ce:lts \
        --admin-password="${admin_hash}" >/dev/null
    ok "Portainer started with pre-seeded admin (user: admin, password: $pw_file)"
}

# ---- Phase 8: Duplicati --------------------------------------------------
# Pre-seeds the WebUI password. Without this, `:8200` is reachable without
# authentication between container start and first admin visit — and
# `/:/source:ro` lets any LAN browser read the whole filesystem, including
# the .env files that hold the DB encryption keys.
#
# Also pre-creates /var/backups/duplicati as a local-destination dir and
# writes an import-ready JSON so the user can one-click set up a backup of
# the load-bearing state (~/vibe-tb/, ~/vibe-mb/, docker volumes, nginx conf).
phase_8_duplicati() {
    phase "PHASE 8 — Deploy Duplicati Backup"

    mkdir -p "$HOME/vibe-duplicati"
    local pw_file="$HOME/vibe-duplicati/webui-password"
    touch "$pw_file"
    chmod 600 "$pw_file"
    local webui_pw
    if [ -s "$pw_file" ]; then
        webui_pw="$(cat "$pw_file")"
    else
        webui_pw="$(openssl rand -base64 32 | tr -d '=+/' | head -c 24)"
        printf '%s\n' "$webui_pw" > "$pw_file"
        chmod 600 "$pw_file"
    fi

    # Local backup destination. Outside $HOME so it survives user-home wipes
    # and so Duplicati (running as the container's abc user) can always write.
    sudo mkdir -p /var/backups/duplicati
    sudo chmod 0777 /var/backups/duplicati

    if container_running duplicati; then
        ok "Duplicati already running (credentials in $pw_file)"
    else
        container_exists duplicati && sudo docker rm -f duplicati >/dev/null
        sudo docker run -d \
            --name duplicati \
            --restart=always \
            --network kisaes-net \
            -p 8200:8200 \
            -e "CLI_ARGS=--webservice-password=${webui_pw} --webservice-allowed-hostnames=*" \
            -v duplicati_config:/data \
            -v /:/source:ro \
            -v /var/backups/duplicati:/backups \
            lscr.io/linuxserver/duplicati:latest >/dev/null
        ok "Duplicati started with pre-seeded password (file: $pw_file)"
    fi

    # Emit an import-ready backup config pointing at the local destination.
    # User imports via Duplicati UI: Add backup → Import from a file.
    local import_file="$HOME/vibe-duplicati/vibe-default-backup.json"
    cat > "$import_file" <<EOF
{
  "CreatedByVersion": "2.0.0.0",
  "Backup": {
    "Name": "Vibe appliance — full state",
    "Description": "Load-bearing state: app env files, docker volumes, nginx conf. Without \\\$HOME/vibe-*/.env the encrypted DBs are unrecoverable.",
    "TargetURL": "file:///backups/vibe-appliance",
    "Tags": []
  },
  "Sources": [
    { "Path": "/source${HOME}/vibe-tb/",      "FilterGroups": ["DefaultExcludes"] },
    { "Path": "/source${HOME}/vibe-mb/",      "FilterGroups": ["DefaultExcludes"] },
    { "Path": "/source/var/lib/docker/volumes/", "FilterGroups": ["DefaultExcludes"] },
    { "Path": "/source/etc/nginx/",           "FilterGroups": ["DefaultExcludes"] },
    { "Path": "/source/var/www/kisaes/",      "FilterGroups": ["DefaultExcludes"] }
  ],
  "Schedule": {
    "Repeat": "1D",
    "AllowedDays": ["mon","tue","wed","thu","fri","sat","sun"]
  }
}
EOF
    chmod 600 "$import_file"
    ok "Default backup config: $import_file (import via :8200 UI)"
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
        warn "A URL will appear below — open it in a browser to register this node."
        warn "Auth window: 10 minutes. After that the phase gives up so provisioning"
        warn "finishes; resume later with: sudo tailscale up --ssh --accept-dns"
        # timeout (not tailscale's builtin timeout flag) so we can keep ERR trap
        # meaningful. Exit 124 = timeout expired; treat that as non-fatal here so
        # the rest of the box (nginx, firewall, mDNS) still comes up.
        if ! sudo timeout 600 tailscale up --ssh --accept-dns; then
            warn "Tailscale auth did not complete in 10 minutes — continuing without it."
            warn "To finish later: sudo tailscale up --ssh --accept-dns"
            return 0
        fi
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

# ---- Phase 12b: mDNS aliases --------------------------------------------
# Publish <VIBE_DOMAIN>, tb.<VIBE_DOMAIN>, mb.<VIBE_DOMAIN> as mDNS A records
# so any client on the LAN (macOS, Linux, Windows 10 1803+, iOS, Android 12+)
# resolves them without /etc/hosts edits or router DNS. Only meaningful when
# VIBE_DOMAIN ends in .local — otherwise this phase is skipped.
phase_12b_mdns() {
    phase "PHASE 12b — Publish mDNS aliases"
    if [[ "$VIBE_DOMAIN" != *.local ]]; then
        warn "VIBE_DOMAIN=${VIBE_DOMAIN} is not a .local domain — skipping mDNS publish."
        warn "Configure DNS for ${VIBE_DOMAIN} via your router or /etc/hosts instead."
        return 0
    fi
    if ! command -v avahi-publish &>/dev/null; then
        err "avahi-publish not found. Phase 1 should have installed avahi-utils."
        return 1
    fi

    # Publisher script: detects LAN IP at start-up and publishes three aliases.
    # Runs in foreground (systemd Type=simple) so Restart=always works.
    sudo tee /usr/local/bin/vibe-mdns-publish > /dev/null <<'EOF'
#!/usr/bin/env bash
# Publish <DOMAIN>, tb.<DOMAIN>, mb.<DOMAIN> via mDNS. Managed by systemd.
set -eu
DOMAIN="${1:?usage: vibe-mdns-publish <domain>}"

# Prefer an explicit MDNS_IP, else auto-detect the LAN IP (RFC1918, not CGNAT).
# Filters out Tailscale (100.64.0.0/10) and link-local (169.254.0.0/16).
if [ -n "${MDNS_IP:-}" ]; then
    IP="$MDNS_IP"
else
    IP="$(ip -4 -o addr show scope global \
            | awk '{print $4}' | cut -d/ -f1 \
            | grep -E '^(10\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[01])\.)' \
            | head -1 || true)"
fi
if [ -z "${IP:-}" ]; then
    echo "vibe-mdns: could not detect a LAN IPv4 (set MDNS_IP=... to override)" >&2
    exit 1
fi

echo "vibe-mdns: publishing ${DOMAIN}, tb.${DOMAIN}, mb.${DOMAIN} -> ${IP}"
# Kill all children on exit so systemd restart cleanly reclaims the records.
trap 'kill 0' EXIT INT TERM
avahi-publish -a -R "${DOMAIN}"    "$IP" &
avahi-publish -a -R "tb.${DOMAIN}" "$IP" &
avahi-publish -a -R "mb.${DOMAIN}" "$IP" &
wait
EOF
    sudo chmod +x /usr/local/bin/vibe-mdns-publish

    sudo tee /etc/systemd/system/vibe-mdns.service > /dev/null <<EOF
[Unit]
Description=Publish Vibe mDNS aliases (${VIBE_DOMAIN}, tb.${VIBE_DOMAIN}, mb.${VIBE_DOMAIN})
After=network-online.target avahi-daemon.service
Wants=network-online.target
Requires=avahi-daemon.service

[Service]
Type=simple
ExecStart=/usr/local/bin/vibe-mdns-publish ${VIBE_DOMAIN}
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

    sudo systemctl daemon-reload
    sudo systemctl enable vibe-mdns.service >/dev/null 2>&1
    sudo systemctl restart vibe-mdns.service

    # Give Avahi a couple of seconds to register, then verify with avahi-resolve.
    sleep 2
    if avahi-resolve -n4 "${VIBE_DOMAIN}" >/dev/null 2>&1; then
        ok "mDNS aliases live: ${VIBE_DOMAIN}, tb.${VIBE_DOMAIN}, mb.${VIBE_DOMAIN}"
    else
        warn "vibe-mdns.service started but ${VIBE_DOMAIN} did not resolve yet."
        warn "Check: systemctl status vibe-mdns.service  (may take ~10s on first boot)"
    fi
}

# ---- Phase 12c: Port-based primary listeners -----------------------------
# These are the CANONICAL URLs for TB and MB — the landing page links to
# them, ALLOWED_ORIGIN / APP_BASE_URL / CORS_ORIGIN point at them, and the
# apps' backend-generated absolute URLs (redirects, emails, PDF links)
# match them. Port-based rather than hostname-based because Windows clients
# running Chrome/Edge Secure DNS or Firefox DoH bypass the Windows mDNS
# resolver, so *.kisaes.local fails in-browser even when `ping` succeeds.
# Port URLs work on every client that can reach the LAN IP.
#
# Host header is passed through (no rewrite) so the backend sees the real
# <lan-ip>:<port> Host and generates matching absolute URLs. The hostname
# server blocks in Phase 12 still serve the SPA but API calls via hostname
# get CORS-rejected until upstream multi-origin support lands (see
# KisaesDevLab/Vibe-Trial-Balance#6 and KisaesDevLab/Vibe-MyBooks#32).
phase_12c_ip_ports() {
    phase "PHASE 12c — Port-based primary listeners (3080=TB, 3081=MB)"
    sudo tee /etc/nginx/sites-available/kisaes-ip-ports > /dev/null <<EOF
# Auto-generated by provision.sh. Canonical port-based URLs for TB and MB.
# Host header passes through so the backend-generated absolute URLs match
# the URL the user is on — prevents redirects/emails/PDF links from
# pointing at the hostname URL (which may not resolve on DoH clients).

server {
    listen 3080;
    listen [::]:3080;
    server_name _;
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

server {
    listen 3081;
    listen [::]:3081;
    server_name _;
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
EOF
    sudo ln -sf /etc/nginx/sites-available/kisaes-ip-ports /etc/nginx/sites-enabled/kisaes-ip-ports
    sudo nginx -t
    sudo systemctl reload nginx
    ok "Port-based primary URLs live — ${TB_URL} (TB), ${MB_URL} (MB)"
}

# ---- Phase 13: UFW -------------------------------------------------------
# WARNING: Docker publishes ports via iptables rules that are applied BEFORE
# UFW's DOCKER-USER hook on a stock Ubuntu install. UFW does NOT firewall
# docker-published ports (9443, 8200, 3000, 3001, 8090, etc.). What UFW
# actually protects here is host-level services: SSH (22), host nginx (80),
# Cockpit (9090), and mDNS (5353/udp). Docker-published ports are reachable
# on every interface the host has a route to — fine for a LAN appliance
# behind NAT, NOT fine if this box is ever given a public IP.
phase_13_ufw() {
    phase "PHASE 13 — Configure UFW firewall"
    sudo ufw --force default deny incoming >/dev/null
    sudo ufw --force default allow outgoing >/dev/null
    sudo ufw allow from 192.168.0.0/16 to any port 22   >/dev/null || true
    sudo ufw allow from 192.168.0.0/16 to any port 80   >/dev/null || true
    sudo ufw allow from 192.168.0.0/16 to any port 9090 >/dev/null || true
    # IP:port fallback listeners (Phase 12c) — reached when browser DNS
    # bypasses mDNS (Chrome/Edge Secure DNS, Firefox DoH).
    sudo ufw allow from 192.168.0.0/16 to any port 3080 >/dev/null || true
    sudo ufw allow from 192.168.0.0/16 to any port 3081 >/dev/null || true
    # mDNS — required for .local hostname resolution from LAN clients.
    sudo ufw allow from 192.168.0.0/16 to any port 5353 proto udp >/dev/null || true
    sudo ufw --force enable >/dev/null
    ok "UFW active on host-level ports (22/80/9090/3080/3081; mDNS 5353/udp)"
    warn "UFW does NOT protect docker-published ports (9443, 8200, 3000, 3001, 8090)."
    warn "Docker's iptables rules run before UFW's DOCKER-USER chain. These ports"
    warn "are LAN-reachable regardless of UFW. Safe for a LAN appliance behind NAT;"
    warn "do NOT expose this host to the public internet without fronting it with"
    warn "a separate firewall or installing ufw-docker."
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

    # Deep health: go through host nginx → container nginx → Node server,
    # so a 200 here proves the whole chain is live (not just that nginx can
    # serve an error page). /api/v1/health on TB is implemented in the server
    # route table; /api/health on MB does a real SELECT 1 against Postgres.
    local tb_body mb_body
    tb_body="$(curl -fsS --max-time 10 -H "Host: tb.${VIBE_DOMAIN}" http://localhost/api/v1/health 2>/dev/null || true)"
    if echo "$tb_body" | grep -qiE '"status"\s*:\s*"ok"|"ok"\s*:\s*true'; then
        ok "TB /api/v1/health → server reachable"
    else
        err "TB /api/v1/health did not return ok (body: ${tb_body:-<empty>})"
        err "  Check: sudo docker logs --tail 50 vibe-tb-server"
        fail=1
    fi

    mb_body="$(curl -fsS --max-time 10 -H "Host: mb.${VIBE_DOMAIN}" http://localhost/api/health 2>/dev/null || true)"
    if echo "$mb_body" | grep -q '"status":"ok"'; then
        ok "MB /api/health → server + DB OK"
    elif echo "$mb_body" | grep -q '"status":"degraded"'; then
        # Server is reachable but its DB probe failed. App is running but not
        # functional — warn loudly, but don't flip fail=1: the degraded state
        # is recoverable (DB catching up, first-boot migration, etc.) whereas
        # an empty body means the server never came up at all.
        warn "MB /api/health → degraded (DB probe failed). Body: $mb_body"
        warn "  Check: sudo docker logs --tail 50 vibe-mb-app   sudo docker logs --tail 50 vibe-mb-db"
    else
        err "MB /api/health did not return ok/degraded (body: ${mb_body:-<empty>})"
        err "  Check: sudo docker logs --tail 50 vibe-mb-app"
        fail=1
    fi

    # Cheap surface-level landing check — separate because a dead backend
    # shouldn't mask a working landing page. Still fails the verify, though:
    # a non-200 SPA means the user can't even load the app to see the error.
    code="$(curl -s -o /dev/null -w '%{http_code}' -H "Host: tb.${VIBE_DOMAIN}" http://localhost/)"
    if [ "$code" = "200" ]; then
        ok "TB SPA bundle served (HTTP 200)"
    else
        err "TB SPA HTTP $code"; fail=1
    fi
    code="$(curl -s -o /dev/null -w '%{http_code}' -H "Host: mb.${VIBE_DOMAIN}" http://localhost/)"
    if [ "$code" = "200" ]; then
        ok "MB SPA bundle served (HTTP 200)"
    else
        err "MB SPA HTTP $code"; fail=1
    fi

    if [[ "$VIBE_DOMAIN" == *.local ]]; then
        if systemctl is-active --quiet vibe-mdns.service; then
            if avahi-resolve -n4 "${VIBE_DOMAIN}" >/dev/null 2>&1; then
                ok "mDNS: ${VIBE_DOMAIN} resolves locally"
            else
                warn "mDNS: vibe-mdns.service active but ${VIBE_DOMAIN} not resolving yet"
            fi
        else
            err "mDNS: vibe-mdns.service is not active"; fail=1
        fi
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
    phase_12b_mdns
    phase_12c_ip_ports
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

    if [[ "$VIBE_DOMAIN" == *.local ]]; then
        echo "${BOLD}Primary URLs${RESET} (port-based — work on every client that can reach"
        echo "this box's LAN IP, including Windows with Secure DNS / DoH):"
        echo ""
        echo "  ${TB_URL}/   → Vibe Trial Balance"
        echo "  ${MB_URL}/   → Vibe MyBooks"
        echo ""
        echo "${BOLD}Landing page${RESET} is still hostname-based via mDNS:"
        echo "  http://${VIBE_DOMAIN}/           (static HTML — no CORS, no API)"
        echo "  http://${LAN_IP}/                (IP fallback — same page)"
        echo ""
        echo "mDNS resolution for the landing works on:"
        echo "  • macOS / iOS / Android 12+          (native mDNS)"
        echo "  • Ubuntu / most Linux desktops       (nss-mdns via avahi)"
        echo "  • Windows 10 1803+ / Windows 11      (native mDNS — set network"
        echo "      profile to Private, not Public, or Defender Firewall blocks it)"
        echo ""
        echo "${BOLD}Why the apps are port-based, not hostname-based:${RESET}"
        echo "  Windows Chrome / Edge Secure DNS and Firefox DoH bypass the mDNS"
        echo "  resolver, so http://tb.${VIBE_DOMAIN}/ fails in-browser even when"
        echo "  \`ping\` works. Port URLs have no DNS dependency. The hostname"
        echo "  URLs (http://tb.${VIBE_DOMAIN}/, http://mb.${VIBE_DOMAIN}/) still"
        echo "  serve the SPA bundle but API calls are CORS-rejected until upstream"
        echo "  multi-origin support lands (KisaesDevLab/Vibe-Trial-Balance#6,"
        echo "  KisaesDevLab/Vibe-MyBooks#32)."
        echo ""
        if [ -n "$ts_ip" ]; then
            echo "${BOLD}Via Tailscale${RESET} (mDNS doesn't traverse the overlay):"
            echo "  http://$ts_ip:3080/   → Vibe Trial Balance"
            echo "  http://$ts_ip:3081/   → Vibe MyBooks"
            echo "  ↑ CORS-breaks unless you set LAN_IP=$ts_ip and re-provision,"
            echo "    or wait for the upstream multi-origin PRs to merge."
            echo ""
        fi
        echo "${BOLD}DHCP caveat${RESET} — the LAN IP ($LAN_IP) is baked into ALLOWED_ORIGIN,"
        echo "APP_BASE_URL, and CORS_ORIGIN. If this IP changes (DHCP reshuffle),"
        echo "re-run ./provision.sh to propagate. Set a DHCP reservation or static"
        echo "IP to avoid needing that."
        echo ""
    else
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
    fi
    echo "${BOLD}Then visit:${RESET}"
    echo "  • ${LANDING_URL}/         — landing page"
    echo "  • ${TB_URL}/              — Vibe Trial Balance"
    echo "  • ${MB_URL}/              — Vibe MyBooks"
    echo "  • https://${lan_ip:-<host>}:9443  — Portainer (admin / see credentials below)"
    echo "  • https://${lan_ip:-<host>}:9090  — Cockpit (log in with your OS user)"
    echo "  • http://${lan_ip:-<host>}:8200   — Duplicati (password below; import job from ~/vibe-duplicati/)"
    echo ""
    echo "${BOLD}Credentials${RESET} (chmod 600 — back these up alongside your .env files):"
    echo "  • Portainer admin: user=admin  password in ~/vibe-portainer/admin-password"
    echo "  • Duplicati WebUI: password in ~/vibe-duplicati/webui-password"
    echo ""
    echo "${BOLD}Secrets${RESET} (auto-generated, load-bearing — losing these bricks the DBs):"
    echo "  • ~/vibe-tb/.env  (DB_PASSWORD, JWT_SECRET, ENCRYPTION_KEY, ALLOWED_ORIGIN)"
    echo "  • ~/vibe-mb/.env  (POSTGRES_PASSWORD, JWT_SECRET, BACKUP_ENCRYPTION_KEY, CORS_ORIGIN)"
    echo ""
    echo "${BOLD}Duplicati backup${RESET} — after first login at :8200:"
    echo "  1. Set a strong WebUI password (overrides the pre-seeded one)"
    echo "  2. Add backup → Import from a file → ~/vibe-duplicati/vibe-default-backup.json"
    echo "  3. Change the destination from the default file:///backups/vibe-appliance"
    echo "     to something OFF-BOX (S3, SFTP, another disk) — a local-only backup"
    echo "     doesn't survive the SSD dying."
    echo ""
    echo "${BOLD}CORS note${RESET} — both apps allow exactly ONE browser origin each:"
    echo "  TB: ALLOWED_ORIGIN=${TB_URL}"
    echo "  MB: CORS_ORIGIN=${MB_URL}"
    echo "If you need to reach the apps via a different URL (LAN IP, Tailscale IP,"
    echo "HTTPS reverse proxy, etc.), edit those values in the .env files and"
    echo "restart the stack:  cd ~/vibe-tb && sudo docker compose --env-file .env up -d"
    echo ""
    echo "${BOLD}GLM-OCR${RESET} is running at http://127.0.0.1:8090/ (container-to-container"
    echo "via vibe-glm-ocr:8090). Vibe TB and Vibe MB do not yet call it by default —"
    echo "wire it up per each app's Admin UI once the app-side support lands."
    echo ""
    if command -v claude &>/dev/null; then
        echo "Run 'claude' from this directory for ongoing maintenance help."
        echo ""
    fi
}

main "$@"
