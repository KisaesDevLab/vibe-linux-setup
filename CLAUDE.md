# CLAUDE.md — Vibe Linux Setup

> **Primary install path is now `./provision.sh`** — an idempotent bash script that executes every phase below end-to-end with no LLM in the loop. This document remains the authoritative reference for what each phase does and is useful when debugging a failed provision or performing manual maintenance. If a user asks you to "run the provisioning guide," prefer executing `provision.sh` over walking through these phases by hand.

You are provisioning a fresh Ubuntu Server 24.04 LTS mini PC. Execute each phase in order. After each phase, run the verification command(s) and confirm they pass before moving on. If a verification fails, diagnose and fix before continuing.

Do NOT skip phases. Do NOT combine phases. Execute one phase at a time and verify.

---

## PHASE 1: System Update & Base Packages

```bash
sudo apt update && sudo apt upgrade -y
sudo apt install -y curl wget gnupg ca-certificates lsb-release software-properties-common nginx
```

**Verify:**
```bash
nginx -v
curl --version | head -1
```

---

## PHASE 2: Install Docker Engine & Compose

```bash
sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
sudo chmod a+r /etc/apt/keyrings/docker.gpg

echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
  https://download.docker.com/linux/ubuntu \
  $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
  sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

sudo apt update
sudo apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
```

Add the current user to the docker group:

```bash
sudo usermod -aG docker $USER
```

Enable on boot:

```bash
sudo systemctl enable docker containerd
```

**Verify:**
```bash
docker --version
docker compose version
sudo systemctl is-enabled docker
sudo systemctl is-enabled containerd
```

> Note: The `newgrp docker` command cannot be run non-interactively. The user will need to log out and back in, or you can prefix docker commands with `sudo` for the remainder of this session.

---

## PHASE 3: Create Shared Docker Network

```bash
sudo docker network create kisaes-net
```

**Verify:**
```bash
sudo docker network ls | grep kisaes-net
```

---

## PHASE 4: Deploy GLM-OCR

Run the self-contained GLM-OCR appliance on the shared network. The GGUF model is baked into the image — no separate model pull needed.

```bash
sudo docker run -d \
  --name vibe-glm-ocr \
  --restart=always \
  --network kisaes-net \
  -p 8090:8090 \
  --log-driver json-file \
  --log-opt max-size=50m \
  --log-opt max-file=5 \
  ghcr.io/kisaesdevlab/vibe-glm-ocr:latest
```

Wait for the model to load (~10s first boot), then check health:

```bash
sleep 15
curl -fsS http://localhost:8090/health
```

**Verify:**
```bash
sudo docker ps --filter name=vibe-glm-ocr --format "{{.Names}} {{.Status}}"
curl -fsS http://localhost:8090/health
```

The container should be `Up` and `/health` should return `{"status":"ok"}`.

> Note: GLM-OCR serves an OpenAI-compatible API at `/v1/chat/completions`. The Vibe TB and Vibe MB apps currently expect an Ollama-style endpoint for local OCR, so wiring them to this service requires an app-side change that is **out of scope for this provisioning guide**. Configure the OCR endpoint via each app's Admin UI once the apps are updated.

---

## PHASE 5: Deploy Vibe Trial Balance

Vibe TB ships as **three containers**: `db` (Postgres), `server` (Node API, internal-only on :3001), and `client` (Nginx serving the SPA + proxying /api/* to server). See the authoritative source at `KisaesDevLab/Vibe-Trial-Balance/docker-compose.prod.images.yml`.

Generate secrets and write `~/vibe-tb/.env`:

```bash
mkdir -p ~/vibe-tb
cat > ~/vibe-tb/.env <<EOF
DB_PASSWORD=$(openssl rand -hex 32)
JWT_SECRET=$(openssl rand -hex 32)
ENCRYPTION_KEY=$(openssl rand -hex 32)
ALLOWED_ORIGIN=http://tb.kisaes.lan
APP_BASE_URL=http://tb.kisaes.lan
EOF
chmod 600 ~/vibe-tb/.env
```

Write `~/vibe-tb/docker-compose.yml`. The client is remapped from `80:80` to **`3000:80`** so host nginx can own port 80 for hostname routing:

```yaml
services:
  db:
    image: postgres:16-alpine
    container_name: vibe-tb-db
    restart: always
    environment:
      POSTGRES_USER: vibetb
      POSTGRES_PASSWORD: ${DB_PASSWORD}
      POSTGRES_DB: vibe_tb_db
    volumes: [pgdata:/var/lib/postgresql/data]
    networks: [kisaes-net]
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U vibetb -d vibe_tb_db"]
      interval: 10s
      timeout: 5s
      retries: 5

  server:
    image: ghcr.io/kisaesdevlab/vibe-tb-server:latest
    container_name: vibe-tb-server
    restart: always
    depends_on: { db: { condition: service_healthy } }
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
    volumes:
      - uploads:/app/server/uploads
      - backups:/app/server/backups
    expose: ["3001"]
    networks: [kisaes-net]

  client:
    image: ghcr.io/kisaesdevlab/vibe-tb-client:latest
    container_name: vibe-tb-client
    restart: always
    depends_on: [server]
    ports: ["3000:80"]
    networks: [kisaes-net]

volumes:
  pgdata:
  uploads:
  backups:

networks:
  kisaes-net:
    external: true
```

Then deploy:

```bash
cd ~/vibe-tb && sudo docker compose --env-file .env up -d
```

**Verify:**
```bash
sudo docker ps --filter name=vibe-tb --format "{{.Names}} {{.Status}}"
```

All three (`vibe-tb-db`, `vibe-tb-server`, `vibe-tb-client`) should show as running.

---

## PHASE 6: Deploy Vibe MyBooks

Vibe MB is a single app image plus Postgres + Redis. Authoritative source: `KisaesDevLab/Vibe-MyBooks/docker-compose.prod.yml`. The Postgres user/db is **`kisbooks`** (not `vibedb`), the app listens on **3001** (not 3000), and `/data` must be a host bind mount so uploads and backups survive container recreate.

Generate secrets and write `~/vibe-mb/.env`:

```bash
mkdir -p ~/vibe-mb/data
cat > ~/vibe-mb/.env <<EOF
POSTGRES_PASSWORD=$(openssl rand -hex 32)
JWT_SECRET=$(openssl rand -hex 32)
BACKUP_ENCRYPTION_KEY=$(openssl rand -hex 32)
CORS_ORIGIN=http://mb.kisaes.lan
EOF
chmod 600 ~/vibe-mb/.env
```

Write `~/vibe-mb/docker-compose.yml`:

```yaml
services:
  db:
    image: postgres:16-alpine
    container_name: vibe-mb-db
    restart: always
    environment:
      POSTGRES_USER: kisbooks
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
      POSTGRES_DB: kisbooks
    volumes: [pgdata:/var/lib/postgresql/data]
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
    volumes: [redis-data:/data]
    networks: [kisaes-net]
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 5s
      timeout: 5s
      retries: 5

  app:
    image: ghcr.io/kisaesdevlab/vibe-mybooks:latest
    container_name: vibe-mb-app
    restart: always
    depends_on:
      db:    { condition: service_healthy }
      redis: { condition: service_healthy }
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
    ports: ["3001:3001"]
    networks: [kisaes-net]

volumes:
  pgdata:
  redis-data:

networks:
  kisaes-net:
    external: true
```

Then deploy:

```bash
cd ~/vibe-mb && sudo docker compose --env-file .env up -d
```

**Verify:**
```bash
sudo docker ps --filter name=vibe-mb --format "{{.Names}} {{.Status}}"
```

All three (`vibe-mb-app`, `vibe-mb-db`, `vibe-mb-redis`) should show as running.

---

## PHASE 7: Deploy Portainer CE

```bash
sudo docker volume create portainer_data

sudo docker run -d \
  --name portainer \
  --restart=always \
  --network kisaes-net \
  -p 8000:8000 \
  -p 9443:9443 \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v portainer_data:/data \
  portainer/portainer-ce:lts
```

**Verify:**
```bash
sudo docker ps --filter name=portainer --format "{{.Names}} {{.Status}}"
```

---

## PHASE 8: Deploy Duplicati Backup

```bash
sudo docker run -d \
  --name duplicati \
  --restart=always \
  --network kisaes-net \
  -p 8200:8200 \
  -v duplicati_config:/data \
  -v /:/source:ro \
  lscr.io/linuxserver/duplicati:latest
```

**Verify:**
```bash
sudo docker ps --filter name=duplicati --format "{{.Names}} {{.Status}}"
```

---

## PHASE 9: Install & Configure Tailscale

```bash
curl -fsSL https://tailscale.com/install.sh | sh
sudo systemctl enable tailscaled
```

Bring Tailscale up with SSH and MagicDNS:

```bash
sudo tailscale up --ssh --accept-dns
```

> This will print a URL. The user must open this URL in a browser on another device to authenticate. Pause here and tell the user to complete authentication before continuing.

**Verify:**
```bash
tailscale status
tailscale ip -4
```

Should return a `100.x.x.x` IP address.

---

## PHASE 10: Install Cockpit

```bash
sudo apt install -y cockpit cockpit-networkmanager cockpit-storaged cockpit-packagekit
sudo systemctl enable --now cockpit.socket
```

**Verify:**
```bash
sudo systemctl is-enabled cockpit.socket
sudo systemctl is-active cockpit.socket
```

Both should return `enabled` and `active`.

---

## PHASE 11: Deploy Landing Page

Copy the landing page from this repo's `assets/` directory:

```bash
sudo mkdir -p /var/www/kisaes
sudo cp assets/landing.html /var/www/kisaes/index.html
```

> This command assumes you are running from the repo root (`~/vibe-Linux-Setup/`). If not, use the full path to the repo's assets directory.

**Verify:**
```bash
ls -la /var/www/kisaes/index.html
head -5 /var/www/kisaes/index.html
```

The `head` output should start with `<!DOCTYPE html>`.

---

## PHASE 12: Configure Nginx Reverse Proxy (hostname-based)

Routing is by **Host header**, not URL path. Three `server_name` blocks serve the three apps. The provisioner uses `VIBE_DOMAIN` (default `kisaes.lan`) — substitute your actual value below.

Remove the default site and write the Kisaes proxy config:

```bash
sudo rm -f /etc/nginx/sites-enabled/default
```

Write `/etc/nginx/sites-available/kisaes` with this exact content (replace `kisaes.lan` with your `VIBE_DOMAIN` if different):

```nginx
# Landing page — http://kisaes.lan
server {
    listen 80;
    listen [::]:80;
    server_name kisaes.lan;

    root /var/www/kisaes;
    index index.html;

    location / {
        try_files $uri $uri/ =404;
    }

    location ~* \.(css|js|png|jpg|svg|ico|woff2?)$ {
        root /var/www/kisaes;
        expires 7d;
    }
}

# Vibe Trial Balance — http://tb.kisaes.lan
server {
    listen 80;
    listen [::]:80;
    server_name tb.kisaes.lan;
    client_max_body_size 50m;

    location / {
        proxy_pass http://127.0.0.1:3000;
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

# Vibe MyBooks — http://mb.kisaes.lan
server {
    listen 80;
    listen [::]:80;
    server_name mb.kisaes.lan;
    client_max_body_size 50m;

    location / {
        proxy_pass http://127.0.0.1:3001;
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

# Catch-all: unknown Host → redirect to landing
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name _;
    return 302 http://kisaes.lan$request_uri;
}
```

Enable and start:

```bash
sudo ln -sf /etc/nginx/sites-available/kisaes /etc/nginx/sites-enabled/kisaes
sudo nginx -t
sudo systemctl restart nginx
sudo systemctl enable nginx
```

**Verify:**
```bash
sudo nginx -t
sudo systemctl is-active nginx
curl -s -o /dev/null -w "%{http_code}" http://localhost/
```

`nginx -t` should say `syntax is ok` and `test is successful`. The curl should return `200`.

---

## PHASE 13: Configure UFW Firewall

```bash
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow from 192.168.0.0/16 to any port 22
sudo ufw allow from 192.168.0.0/16 to any port 80
sudo ufw allow from 192.168.0.0/16 to any port 9090
sudo ufw --force enable
```

**Verify:**
```bash
sudo ufw status verbose
```

Should show `Status: active` with rules for ports 22, 80, and 9090.

---

## PHASE 14: Final Verification

Run all checks in sequence. Every line must pass.

```bash
echo "=== Docker ==="
docker --version
sudo docker network ls | grep kisaes-net

echo "=== Containers ==="
sudo docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" | sort

echo "=== GLM-OCR ==="
curl -fsS http://localhost:8090/health

echo "=== Tailscale ==="
tailscale ip -4
sudo systemctl is-enabled tailscaled

echo "=== Cockpit ==="
sudo systemctl is-active cockpit.socket

echo "=== Nginx ==="
sudo nginx -t 2>&1
curl -s -o /dev/null -w "Landing page: HTTP %{http_code}\n" http://localhost/

echo "=== UFW ==="
sudo ufw status | head -5

echo "=== Boot services ==="
for svc in docker containerd tailscaled cockpit.socket nginx; do
  echo "$svc: $(sudo systemctl is-enabled $svc)"
done
```

### Expected container list (9 containers, all running):

| Container        | Port(s)           |
|------------------|-------------------|
| vibe-glm-ocr     | 8090              |
| vibe-tb-db       | 5432 (internal)   |
| vibe-tb-server   | 3001 (internal)   |
| vibe-tb-client   | 3000 → 80         |
| vibe-mb-db       | 5432 (internal)   |
| vibe-mb-redis    | 6379 (internal)   |
| vibe-mb-app      | 3001              |
| portainer        | 9443, 8000        |
| duplicati        | 8200              |

### Access points after completion (with DNS pointed at this box):

| URL                                   | Service                         |
|---------------------------------------|---------------------------------|
| `http://kisaes.lan`                   | Landing page                    |
| `http://tb.kisaes.lan`                | Vibe Trial Balance              |
| `http://mb.kisaes.lan`                | Vibe MyBooks                    |
| `https://<ip>:9090`                   | Cockpit (server mgmt)           |
| `https://<ip>:9443`                   | Portainer (Docker mgmt)         |
| `http://<ip>:8200`                    | Duplicati (backups)             |
| Any of the above via Tailscale IP     | Works after DNS is configured   |

Substitute `kisaes.lan` with whatever `VIBE_DOMAIN` was set to. Clients must resolve the three hostnames to this box (via `/etc/hosts`, router DNS, Pi-hole, or Tailscale Split DNS).

---

## POST-PROVISIONING REMINDERS (tell the user)

1. **Configure DNS for the three hostnames** — `${VIBE_DOMAIN}`, `tb.${VIBE_DOMAIN}`, `mb.${VIBE_DOMAIN}` must resolve to this box. Pick one: (a) `/etc/hosts` on each client machine, (b) Tailscale Split DNS, (c) router DNS / Pi-hole.
2. **Portainer admin** — First visit to `:9443` requires creating an admin account. Do this within 5 minutes of startup or Portainer locks itself.
3. **Duplicati backup schedule** — Visit `:8200` and configure backup jobs for `/var/lib/docker/volumes/`, `~/vibe-tb/` (includes `.env`), `~/vibe-mb/` (includes `.env` and `./data/`), `/etc/nginx/`, and `/var/www/kisaes/`.
4. **Secrets** — `provision.sh` auto-generates `DB_PASSWORD` / `JWT_SECRET` / `ENCRYPTION_KEY` / `BACKUP_ENCRYPTION_KEY` into `~/vibe-tb/.env` and `~/vibe-mb/.env` (chmod 600). These files are load-bearing — back them up separately from the database dumps (without them, the DBs are unrecoverable).
5. **Anthropic API key (optional)** — To use Claude-backed AI features in Vibe TB, add `ANTHROPIC_API_KEY=sk-ant-...` to `~/vibe-tb/.env` and restart: `cd ~/vibe-tb && sudo docker compose --env-file .env up -d`. Also configurable later inside the app under Admin → Settings → AI Provider.
6. **Origins** — `ALLOWED_ORIGIN` (TB) and `CORS_ORIGIN` (MB) are set to the hostname URLs. If you also want to access via LAN IP or Tailscale IP, edit those values in the `.env` files and restart the respective compose stack.
