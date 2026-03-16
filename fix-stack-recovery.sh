#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════════
# EtherOS — Full Stack Recovery + Sprint 4A Deploy
# Run on VPS as root: bash fix-stack-recovery.sh
#
# What this does:
#   1. Restores the correct nginx config (LetsEncrypt + ISP portal + marketplace)
#   2. Restores the correct nginx.conf (needed after bootstrap overwrote it)
#   3. Ensures ISP portal + marketplace backends are running
#   4. Deploys Sprint 4A server.js + static bundle
#   5. Reloads nginx and verifies all endpoints
# ═══════════════════════════════════════════════════════════════════════════════
set -euo pipefail

GREEN='\033[0;32m'; CYAN='\033[0;36m'; YELLOW='\033[1;33m'
BOLD='\033[1m'; RED='\033[0;31m'; NC='\033[0m'

E="/opt/etheros-edge"
RAW="https://raw.githubusercontent.com/FGN2025/etheros-edge-deploy/main"
DOMAIN="edge.etheros.ai"

echo -e "${CYAN}${BOLD}━━━ EtherOS Stack Recovery + Sprint 4A ━━━${NC}"
echo ""

# ── 1. Restore correct nginx.conf (main config) ──────────────────────────────
echo -e "${YELLOW}▸${NC} Restoring nginx.conf..."
cat > "$E/nginx/nginx.conf" << 'NGINXMAIN'
user nginx;
worker_processes auto;
error_log /var/log/nginx/error.log warn;
pid /var/run/nginx.pid;
events { worker_connections 4096; use epoll; multi_accept on; }
http {
  include /etc/nginx/mime.types;
  default_type application/octet-stream;
  sendfile on; tcp_nopush on; tcp_nodelay on;
  keepalive_timeout 75s; client_max_body_size 100m; server_tokens off;
  gzip on; gzip_vary on; gzip_proxied any; gzip_comp_level 6;
  gzip_types text/plain text/css application/json application/javascript text/javascript;
  include /etc/nginx/conf.d/*.conf;
}
NGINXMAIN
echo -e "  ${GREEN}✓${NC} nginx.conf restored"

# ── 2. Restore correct vhost (with LetsEncrypt + all location blocks) ─────────
echo -e "${YELLOW}▸${NC} Restoring vhost config..."
mkdir -p "$E/nginx/conf.d"
cat > "$E/nginx/conf.d/etheros-edge.conf" << 'VHOST'
upstream open_webui {
    server etheros-open-webui:8080;
}
upstream ollama_backend {
    server etheros-ollama:11434;
}
upstream grafana_backend {
    server etheros-grafana:3000;
}

# HTTP → HTTPS redirect
server {
    listen 80;
    server_name edge.etheros.ai;
    return 301 https://$host$request_uri;
}

# Main HTTPS server
server {
    listen 443 ssl;
    server_name edge.etheros.ai;

    ssl_certificate     /etc/letsencrypt/live/edge.etheros.ai/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/edge.etheros.ai/privkey.pem;
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_ciphers         HIGH:!aNULL:!MD5;
    ssl_session_cache   shared:SSL:10m;
    ssl_session_timeout 10m;

    client_max_body_size 100M;
    proxy_read_timeout   300s;
    proxy_send_timeout   300s;

    # ── ISP Portal static SPA ─────────────────────────────────────
    location /isp-portal/ {
        alias /opt/etheros-edge/static/isp-portal/;
        try_files $uri $uri/ /isp-portal/index.html;
        add_header Cache-Control "no-cache";
    }
    location /isp-portal/api/ {
        proxy_pass http://etheros-isp-portal-backend:3010/api/;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
    location /isp-portal/health {
        proxy_pass http://etheros-isp-portal-backend:3010/health;
    }

    # ── Agent Marketplace static SPA ──────────────────────────────
    location /marketplace/ {
        alias /opt/etheros-edge/static/marketplace/;
        try_files $uri $uri/ /marketplace/index.html;
        add_header Cache-Control "no-cache";
    }
    location /marketplace/api/ {
        proxy_pass http://etheros-marketplace-backend:3011/api/;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_buffering off;
        proxy_cache off;
        proxy_set_header X-Accel-Buffering no;
        proxy_read_timeout 300s;
        chunked_transfer_encoding on;
    }
    location /marketplace/health {
        proxy_pass http://etheros-marketplace-backend:3011/health;
    }

    # ── Ollama ────────────────────────────────────────────────────
    location /ollama/v1/ {
        rewrite ^/ollama/v1/(.*)$ /v1/$1 break;
        proxy_pass         http://ollama_backend;
        proxy_set_header   Host $host;
        proxy_set_header   X-Real-IP $remote_addr;
        proxy_set_header   X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto $scheme;
    }
    location /ollama/api/ {
        rewrite ^/ollama/api/(.*)$ /api/$1 break;
        proxy_pass         http://ollama_backend;
        proxy_set_header   Host $host;
        proxy_set_header   X-Real-IP $remote_addr;
        proxy_set_header   X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto $scheme;
    }

    # ── Open WebUI (catch-all) ────────────────────────────────────
    location /api/ {
        proxy_pass         http://open_webui;
        proxy_set_header   Host $host;
        proxy_set_header   X-Real-IP $remote_addr;
        proxy_set_header   X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto $scheme;
        proxy_http_version 1.1;
        proxy_set_header   Upgrade $http_upgrade;
        proxy_set_header   Connection "upgrade";
    }
    location /ws/ {
        proxy_pass         http://open_webui;
        proxy_http_version 1.1;
        proxy_set_header   Upgrade $http_upgrade;
        proxy_set_header   Connection "upgrade";
        proxy_set_header   Host $host;
        proxy_set_header   X-Real-IP $remote_addr;
        proxy_set_header   X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto $scheme;
        proxy_read_timeout 3600s;
    }
    location /grafana/ {
        proxy_pass         http://grafana_backend/;
        proxy_set_header   Host $host;
        proxy_set_header   X-Real-IP $remote_addr;
        proxy_set_header   X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto $scheme;
    }
    location / {
        proxy_pass         http://open_webui;
        proxy_set_header   Host $host;
        proxy_set_header   X-Real-IP $remote_addr;
        proxy_set_header   X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto $scheme;
        proxy_http_version 1.1;
        proxy_set_header   Upgrade $http_upgrade;
        proxy_set_header   Connection "upgrade";
    }
}

# Port 8443 — mTLS terminal endpoint
server {
    listen 8443 ssl;
    server_name edge.etheros.ai;
    ssl_certificate     /etc/letsencrypt/live/edge.etheros.ai/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/edge.etheros.ai/privkey.pem;
    ssl_client_certificate /etc/nginx/ssl/etheros-ca.crt;
    ssl_verify_client   optional;
    ssl_protocols       TLSv1.2 TLSv1.3;
    location /v1/ {
        proxy_pass http://ollama_backend/v1/;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
    }
}
VHOST
echo -e "  ${GREEN}✓${NC} Vhost config restored"

# ── 3. Mount LetsEncrypt certs into nginx container ───────────────────────────
# The bootstrap replaced the compose file — it mounts nginx/ssl not letsencrypt.
# We need to symlink or pass the cert volume into the nginx container.
# Check if cert exists
if [[ -f "/etc/letsencrypt/live/${DOMAIN}/fullchain.pem" ]]; then
    echo -e "  ${GREEN}✓${NC} LetsEncrypt cert found"
else
    echo -e "  ${RED}✗${NC}  LetsEncrypt cert NOT found at /etc/letsencrypt/live/${DOMAIN}/"
    echo "     You may need to re-run certbot after stack is back up:"
    echo "     docker stop etheros-nginx && certbot certonly --standalone -d ${DOMAIN} && docker start etheros-nginx"
fi

# ── 4. Update docker-compose.yml to include ISP/Marketplace backends ──────────
# Also fix nginx volumes to mount letsencrypt + static dirs
echo -e "${YELLOW}▸${NC} Updating docker-compose.yml..."
cat > "$E/docker-compose.yml" << 'COMPOSE'
name: etheros-edge
networks:
  edge-internal:
    driver: bridge
  edge-public:
    driver: bridge
volumes:
  ollama-data:
  open-webui-data:
  prometheus-data:
  grafana-data:
services:
  ollama:
    image: ollama/ollama:latest
    container_name: etheros-ollama
    restart: unless-stopped
    networks: [edge-internal]
    volumes:
      - ollama-data:/root/.ollama
    environment:
      - OLLAMA_HOST=0.0.0.0:11434
      - OLLAMA_NUM_PARALLEL=2
      - OLLAMA_MAX_LOADED_MODELS=1
      - OLLAMA_KEEP_ALIVE=5m
    ports:
      - "127.0.0.1:11434:11434"
    healthcheck:
      test: ["CMD","curl","-sf","http://localhost:11434/api/tags"]
      interval: 30s
      timeout: 10s
      retries: 5
      start_period: 120s

  ollama-model-loader:
    image: ollama/ollama:latest
    container_name: etheros-model-loader
    restart: on-failure
    networks: [edge-internal]
    volumes:
      - ollama-data:/root/.ollama
    entrypoint: ["/bin/sh","-c"]
    command:
      - |
        until curl -sf http://ollama:11434/api/tags > /dev/null 2>&1; do sleep 5; done
        ollama pull phi3:mini && ollama pull qwen2:0.5b && echo "Models ready."
    depends_on:
      ollama:
        condition: service_healthy

  open-webui:
    image: ghcr.io/open-webui/open-webui:main
    container_name: etheros-open-webui
    restart: unless-stopped
    networks: [edge-internal]
    volumes:
      - open-webui-data:/app/backend/data
    environment:
      - OLLAMA_BASE_URL=http://ollama:11434
      - WEBUI_SECRET_KEY=etheros-fgn-secret-key-2026-change-me
      - WEBUI_URL=https://edge.etheros.ai
      - ENABLE_SIGNUP=false
      - DEFAULT_USER_ROLE=user
      - ENABLE_COMMUNITY_SHARING=false
      - WEBUI_NAME=EtherOS AI
    ports:
      - "127.0.0.1:3000:8080"
    depends_on:
      ollama:
        condition: service_healthy
    healthcheck:
      test: ["CMD","curl","-sf","http://localhost:8080/health"]
      interval: 30s
      timeout: 5s
      retries: 5
      start_period: 90s

  isp-portal-backend:
    image: node:20-alpine
    container_name: etheros-isp-portal-backend
    restart: unless-stopped
    networks: [edge-internal]
    working_dir: /app
    command: ["node", "server.js"]
    volumes:
      - /opt/etheros-edge/backends/isp-portal:/app:rw
    ports:
      - "127.0.0.1:3010:3010"
    environment:
      - NODE_ENV=production
      - PORT=3010

  marketplace-backend:
    image: node:20-alpine
    container_name: etheros-marketplace-backend
    restart: unless-stopped
    networks: [edge-internal]
    working_dir: /app
    command: ["node", "server.js"]
    volumes:
      - /opt/etheros-edge/backends/marketplace:/app:rw
    ports:
      - "127.0.0.1:3011:3011"
    environment:
      - NODE_ENV=production
      - PORT=3011

  nginx:
    image: nginx:1.25-alpine
    container_name: etheros-nginx
    restart: unless-stopped
    networks: [edge-internal, edge-public]
    ports:
      - "80:80"
      - "443:443"
      - "8443:8443"
    volumes:
      - /opt/etheros-edge/nginx/nginx.conf:/etc/nginx/nginx.conf:ro
      - /opt/etheros-edge/nginx/conf.d:/etc/nginx/conf.d:ro
      - /opt/etheros-edge/nginx/ssl:/etc/nginx/ssl:ro
      - /etc/letsencrypt:/etc/letsencrypt:ro
      - /opt/etheros-edge/static:/opt/etheros-edge/static:ro
    depends_on: [open-webui, isp-portal-backend, marketplace-backend]

  prometheus:
    image: prom/prometheus:latest
    container_name: etheros-prometheus
    restart: unless-stopped
    networks: [edge-internal]
    volumes:
      - /opt/etheros-edge/prometheus/prometheus.yml:/etc/prometheus/prometheus.yml:ro
      - prometheus-data:/prometheus
    command:
      - --config.file=/etc/prometheus/prometheus.yml
      - --storage.tsdb.path=/prometheus
      - --storage.tsdb.retention.time=30d
    ports:
      - "127.0.0.1:9090:9090"

  grafana:
    image: grafana/grafana:latest
    container_name: etheros-grafana
    restart: unless-stopped
    networks: [edge-internal]
    volumes:
      - grafana-data:/var/lib/grafana
      - /opt/etheros-edge/grafana/provisioning:/etc/grafana/provisioning:ro
    environment:
      - GF_SECURITY_ADMIN_PASSWORD=EtherOS-Admin-2026
      - GF_SECURITY_ADMIN_USER=admin
      - GF_SERVER_DOMAIN=edge.etheros.ai
      - GF_SERVER_ROOT_URL=https://edge.etheros.ai/grafana
      - GF_SERVER_SERVE_FROM_SUB_PATH=true
      - GF_ANALYTICS_REPORTING_ENABLED=false
    ports:
      - "127.0.0.1:3001:3000"
    depends_on: [prometheus]
COMPOSE
echo -e "  ${GREEN}✓${NC} docker-compose.yml updated (backends + letsencrypt volume)"

# ── 5. Deploy Sprint 4A: server.js + static assets ───────────────────────────
echo -e "${YELLOW}▸${NC} Deploying Sprint 4A server.js..."
curl -fsSL "${RAW}/backends/isp-portal/server.js" \
     -o "$E/backends/isp-portal/server.js"
echo -e "  ${GREEN}✓${NC} server.js updated"

echo -e "${YELLOW}▸${NC} Deploying Sprint 4A static frontend..."
mkdir -p "$E/static/isp-portal/assets"
curl -fsSL "${RAW}/static/isp-portal/index.html" \
     -o "$E/static/isp-portal/index.html"
curl -fsSL "${RAW}/static/isp-portal/assets/index-Bu9EqVyL.js" \
     -o "$E/static/isp-portal/assets/index-Bu9EqVyL.js"
curl -fsSL "${RAW}/static/isp-portal/assets/index-CtV6q4UG.css" \
     -o "$E/static/isp-portal/assets/index-CtV6q4UG.css"
# Remove old bundles
rm -f "$E/static/isp-portal/assets/index-BZG4XJe4.js"
rm -f "$E/static/isp-portal/assets/index-CHYSB4sm.css"
echo -e "  ${GREEN}✓${NC} Static assets updated"

# ── 6. Ensure node_modules exist in backend dirs ─────────────────────────────
echo -e "${YELLOW}▸${NC} Checking node_modules in ISP Portal backend..."
if [[ ! -d "$E/backends/isp-portal/node_modules" ]]; then
    echo "  Installing npm dependencies..."
    cd "$E/backends/isp-portal" && npm install --omit=dev --quiet
    echo -e "  ${GREEN}✓${NC} node_modules installed"
else
    echo -e "  ${GREEN}✓${NC} node_modules already present"
fi

# ── 7. Bring up the full stack ────────────────────────────────────────────────
echo -e "${YELLOW}▸${NC} Starting full stack (remove-orphans)..."
cd "$E"
docker compose up -d --remove-orphans 2>&1 | tail -20
echo -e "  ${GREEN}✓${NC} Stack started"

# ── 8. Wait for backends to be ready ─────────────────────────────────────────
echo -e "${YELLOW}▸${NC} Waiting for ISP Portal backend (up to 30s)..."
for i in $(seq 1 15); do
    STATUS=$(curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:3010/api/tenant 2>/dev/null || true)
    if [[ "$STATUS" == "200" ]]; then
        echo -e "  ${GREEN}✓${NC} ISP Portal backend alive"
        break
    fi
    sleep 2
done

# ── 9. Reload nginx to pick up restored config ────────────────────────────────
echo -e "${YELLOW}▸${NC} Reloading nginx..."
docker exec etheros-nginx nginx -s reload 2>/dev/null || docker restart etheros-nginx
echo -e "  ${GREEN}✓${NC} Nginx reloaded"

# ── 10. Verify all endpoints ──────────────────────────────────────────────────
echo ""
echo -e "${CYAN}${BOLD}━━━ Endpoint Verification ━━━${NC}"
sleep 2

check_url() {
    local label="$1" url="$2"
    local status
    status=$(curl -sk -o /tmp/resp.txt -w "%{http_code}" "$url" 2>/dev/null || echo "000")
    local body
    body=$(cat /tmp/resp.txt 2>/dev/null | head -c 120)
    if [[ "$status" == "200" || "$status" == "301" || "$status" == "302" ]]; then
        echo -e "  ${GREEN}✓${NC} [$status] $label"
    else
        echo -e "  ${RED}✗${NC}  [$status] $label — $body"
    fi
}

check_url "ISP Portal backend /api/tenant"  "http://127.0.0.1:3010/api/tenant"
check_url "ISP Portal backend /health"      "http://127.0.0.1:3010/health"
check_url "Marketplace backend /health"     "http://127.0.0.1:3011/health"
check_url "Nginx → ISP Portal (HTTPS)"      "https://edge.etheros.ai/isp-portal/"
check_url "Nginx → Marketplace (HTTPS)"     "https://edge.etheros.ai/marketplace/"
check_url "Nginx → Open WebUI (HTTPS)"      "https://edge.etheros.ai/"

echo ""
echo -e "${CYAN}Sprint 4A tenant API:${NC}"
curl -s http://127.0.0.1:3010/api/tenant | python3 -m json.tool 2>/dev/null || \
  curl -s http://127.0.0.1:3010/api/tenant

echo ""
echo -e "${GREEN}${BOLD}━━━ Recovery Complete ━━━${NC}"
echo -e "  ISP Portal:  https://edge.etheros.ai/isp-portal/"
echo -e "  Marketplace: https://edge.etheros.ai/marketplace/"
echo -e "  Open WebUI:  https://edge.etheros.ai/"
echo ""
echo -e "${YELLOW}If nginx shows cert errors, run:${NC}"
echo "  docker stop etheros-nginx"
echo "  certbot certonly --standalone -d edge.etheros.ai"
echo "  docker start etheros-nginx"
