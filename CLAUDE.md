# CLAUDE.md — Vibe Linux Setup

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

Create the directory and compose file:

```bash
mkdir -p ~/vibe-tb
```

Write `~/vibe-tb/docker-compose.yml` with this exact content:

```yaml
services:
  vibe-tb-db:
    image: postgres:16-alpine
    container_name: vibe-tb-db
    restart: always
    environment:
      POSTGRES_USER: vibedb
      POSTGRES_PASSWORD: CHANGE_ME_TB
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
      DATABASE_URL: postgres://vibedb:CHANGE_ME_TB@vibe-tb-db:5432/vibe_tb
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
```

Then deploy:

```bash
cd ~/vibe-tb && sudo docker compose up -d
```

**Verify:**
```bash
sudo docker ps --filter name=vibe-tb --format "{{.Names}} {{.Status}}"
```

Both `vibe-tb-app` and `vibe-tb-db` should show as running.

---

## PHASE 6: Deploy Vibe MyBooks

Create the directory and compose file:

```bash
mkdir -p ~/vibe-mb
```

Write `~/vibe-mb/docker-compose.yml` with this exact content:

```yaml
services:
  vibe-mb-db:
    image: postgres:16-alpine
    container_name: vibe-mb-db
    restart: always
    environment:
      POSTGRES_USER: vibedb
      POSTGRES_PASSWORD: CHANGE_ME_MB
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
      DATABASE_URL: postgres://vibedb:CHANGE_ME_MB@vibe-mb-db:5432/vibe_mb
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
```

Then deploy:

```bash
cd ~/vibe-mb && sudo docker compose up -d
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

## PHASE 12: Configure Nginx Reverse Proxy

Remove the default site and write the Kisaes proxy config:

```bash
sudo rm -f /etc/nginx/sites-enabled/default
```

Write `/etc/nginx/sites-available/kisaes` with this exact content:

```nginx
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name _;

    # Landing page
    root /var/www/kisaes;
    index index.html;

    location = / {
        try_files /index.html =404;
    }

    # Static assets for landing page
    location ~* \.(css|js|png|jpg|svg|ico|woff2?)$ {
        root /var/www/kisaes;
        expires 7d;
    }

    # Vibe Trial Balance
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

    # Vibe MyBooks
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

### Expected container list (8 containers, all running):

| Container        | Port(s)        |
|------------------|----------------|
| vibe-glm-ocr     | 8090           |
| vibe-tb-app      | 3000           |
| vibe-tb-db       | 5432 (internal)|
| vibe-mb-app      | 3001→3000      |
| vibe-mb-db       | 5432 (internal)|
| vibe-mb-redis    | 6379 (internal)|
| portainer        | 9443, 8000     |
| duplicati        | 8200           |

### Access points after completion:

| URL                              | Service                    |
|----------------------------------|----------------------------|
| `http://<ip>`                    | Landing page (TB or MB)    |
| `http://<ip>/tb/`                | Vibe Trial Balance         |
| `http://<ip>/mb/`                | Vibe MyBooks               |
| `https://<ip>:9090`              | Cockpit (server mgmt)      |
| `https://<ip>:9443`              | Portainer (Docker mgmt)    |
| `http://<ip>:8200`               | Duplicati (backups)        |
| All of the above via Tailscale IP | Works with no extra config |

---

## POST-PROVISIONING REMINDERS (tell the user)

1. **Change default passwords** — The compose files use `CHANGE_ME_TB` and `CHANGE_ME_MB` as Postgres passwords. These must be replaced with real secrets before production use.
2. **Portainer admin** — First visit to `:9443` requires creating an admin account. Do this within 5 minutes of startup or Portainer locks itself.
3. **Duplicati backup schedule** — Visit `:8200` and configure backup jobs for `/var/lib/docker/volumes/`, `~/vibe-tb/`, `~/vibe-mb/`, `/etc/nginx/`, and `/var/www/kisaes/`.
4. **Sub-path routing** — If Vibe TB or Vibe MB use React Router, each app needs `basename="/tb"` or `basename="/mb"` set in its router config so client-side routing works under the Nginx sub-paths.
5. **Docker image references** — The compose files reference `ghcr.io/kisaesdevlab/vibe-trial-balance:latest` and `ghcr.io/kisaesdevlab/vibe-mybooks:latest`. Update these to match the actual published image names if different.
