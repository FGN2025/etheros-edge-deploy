#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════════
# EtherOS Edge Node Bootstrap — v1.0
# Deploys the full EtherOS AI terminal stack on any fresh Debian 12 / Ubuntu 22+
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/FGN2025/etheros-edge-deploy/main/bootstrap.sh | bash -s -- \
#     --isp-slug valley-fiber \
#     --isp-name "Valley Fiber" \
#     --domain edge.valleyfiber.com \
#     --accent "#00C2CB" \
#     --email admin@valleyfiber.com \
#     --model auto
#
# Flags:
#   --isp-slug    URL-safe ISP identifier (letters/numbers/hyphens)
#   --isp-name    Display name for the ISP
#   --domain      Full domain for this node (must have A record → this server's IP)
#   --accent      Hex accent color for branding (default: #00C2CB)
#   --email       Admin email for Let's Encrypt + Open WebUI admin
#   --model       AI model: auto | phi3:mini | llama3.1:8b | mistral:7b (default: auto)
#   --skip-cert   Skip Let's Encrypt (useful when DNS isn't ready yet)
#   --skip-model  Skip model pull (pull manually later)
# ═══════════════════════════════════════════════════════════════════════════════
set -euo pipefail

# ── Colors ────────────────────────────────────────────────────────────────────
GREEN='\033[0;32m'; CYAN='\033[0;36m'; YELLOW='\033[1;33m'
BOLD='\033[1m'; RED='\033[0;31m'; NC='\033[0m'

# ── Defaults ──────────────────────────────────────────────────────────────────
ISP_SLUG="etheros-default"
ISP_NAME="EtherOS AI"
DOMAIN="edge.etheros.ai"
ACCENT="#00C2CB"
EMAIL="admin@etheros.ai"
MODEL="auto"
SKIP_CERT=false
SKIP_MODEL=false
EDGE_DIR="/opt/etheros-edge"
REPO="https://raw.githubusercontent.com/FGN2025/etheros-edge-deploy/main"

# ── Parse args ────────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --isp-slug)   ISP_SLUG="$2";   shift 2 ;;
    --isp-name)   ISP_NAME="$2";   shift 2 ;;
    --domain)     DOMAIN="$2";     shift 2 ;;
    --accent)     ACCENT="$2";     shift 2 ;;
    --email)      EMAIL="$2";      shift 2 ;;
    --model)      MODEL="$2";      shift 2 ;;
    --skip-cert)  SKIP_CERT=true;  shift ;;
    --skip-model) SKIP_MODEL=true; shift ;;
    *) echo -e "${RED}Unknown argument: $1${NC}"; exit 1 ;;
  esac
done

# ── Banner ────────────────────────────────────────────────────────────────────
clear
echo -e "${CYAN}${BOLD}"
cat << 'BANNER'
 _____ _   _               ___  ____
| ____| |_| |__   ___ _ __/ _ \/ ___|
|  _| | __| '_ \ / _ \ '__| | | \___ \
| |___| |_| | | |  __/ |  | |_| |___) |
|_____|\__|_| |_|\___|_|   \___/|____/

  Edge Node Bootstrap v1.0
BANNER
echo -e "${NC}"
echo -e "${BOLD}Deploying EtherOS edge node for: ${CYAN}${ISP_NAME}${NC}"
echo -e "  Domain:  ${DOMAIN}"
echo -e "  Slug:    ${ISP_SLUG}"
echo -e "  Model:   ${MODEL}"
echo -e "  Email:   ${EMAIL}"
echo ""

# ── Pre-flight checks ─────────────────────────────────────────────────────────
echo -e "${YELLOW}▸${NC} Running pre-flight checks..."

# Must be root
if [[ $EUID -ne 0 ]]; then
  echo -e "${RED}Error: Must run as root. Use: sudo bash bootstrap.sh${NC}"
  exit 1
fi

# OS check
OS=$(grep -oP '(?<=^ID=).+' /etc/os-release | tr -d '"' 2>/dev/null || echo "unknown")
VERSION=$(grep -oP '(?<=^VERSION_ID=).+' /etc/os-release | tr -d '"' 2>/dev/null || echo "0")
if [[ "$OS" != "debian" && "$OS" != "ubuntu" ]]; then
  echo -e "${YELLOW}Warning: Detected OS '$OS'. Tested on Debian 12 and Ubuntu 22+.${NC}"
fi
echo -e "  ${GREEN}✓${NC} OS: $OS $VERSION"

# RAM check — determines auto model selection
TOTAL_RAM_MB=$(free -m | awk '/^Mem:/{print $2}')
echo -e "  ${GREEN}✓${NC} RAM: ${TOTAL_RAM_MB} MB"

# CPU check
CPUS=$(nproc)
echo -e "  ${GREEN}✓${NC} CPUs: ${CPUS}"

# Disk check — need at least 20 GB free
FREE_DISK_GB=$(df -BG / | awk 'NR==2{gsub("G",""); print $4}')
if [[ $FREE_DISK_GB -lt 15 ]]; then
  echo -e "${RED}Error: Need at least 15 GB free disk. Found: ${FREE_DISK_GB}GB${NC}"
  exit 1
fi
echo -e "  ${GREEN}✓${NC} Disk: ${FREE_DISK_GB}GB free"

# ── Auto model selection ──────────────────────────────────────────────────────
if [[ "$MODEL" == "auto" ]]; then
  if [[ $TOTAL_RAM_MB -ge 12000 ]]; then
    MODEL="llama3.1:8b"
    echo -e "  ${GREEN}✓${NC} Auto-selected model: llama3.1:8b (${TOTAL_RAM_MB}MB RAM ≥ 12GB)"
  elif [[ $TOTAL_RAM_MB -ge 6000 ]]; then
    MODEL="mistral:7b"
    echo -e "  ${GREEN}✓${NC} Auto-selected model: mistral:7b (${TOTAL_RAM_MB}MB RAM ≥ 6GB)"
  else
    MODEL="phi3:mini"
    echo -e "  ${GREEN}✓${NC} Auto-selected model: phi3:mini (${TOTAL_RAM_MB}MB RAM < 6GB)"
  fi
fi

echo ""

# ── Install dependencies ──────────────────────────────────────────────────────
echo -e "${YELLOW}▸${NC} Installing system dependencies..."
apt-get update -qq
apt-get install -y -qq \
  curl wget git python3 python3-pip \
  apt-transport-https ca-certificates gnupg lsb-release \
  certbot nginx-common \
  jq > /dev/null 2>&1
echo -e "  ${GREEN}✓${NC} System packages installed"

# ── Install Docker ────────────────────────────────────────────────────────────
if ! command -v docker &>/dev/null; then
  echo -e "${YELLOW}▸${NC} Installing Docker..."
  curl -fsSL https://get.docker.com | sh > /dev/null 2>&1
  systemctl enable docker --now > /dev/null 2>&1
  echo -e "  ${GREEN}✓${NC} Docker installed: $(docker --version)"
else
  echo -e "  ${GREEN}✓${NC} Docker already installed: $(docker --version)"
fi

# Docker Compose v2 check
if ! docker compose version &>/dev/null; then
  echo -e "${YELLOW}▸${NC} Installing Docker Compose plugin..."
  apt-get install -y -qq docker-compose-plugin > /dev/null 2>&1
fi
echo -e "  ${GREEN}✓${NC} Docker Compose: $(docker compose version --short)"

# Python yaml for compose patching
pip3 install -q pyyaml 2>/dev/null || true
echo -e "  ${GREEN}✓${NC} Python yaml available"

echo ""

# ── Create directory structure ────────────────────────────────────────────────
echo -e "${YELLOW}▸${NC} Setting up EtherOS directory structure..."
mkdir -p \
  "$EDGE_DIR/nginx/conf.d" \
  "$EDGE_DIR/isp-config" \
  "$EDGE_DIR/data/ollama" \
  "$EDGE_DIR/data/open-webui" \
  "$EDGE_DIR/data/prometheus" \
  "$EDGE_DIR/data/grafana"
chmod 750 "$EDGE_DIR/isp-config"
echo -e "  ${GREEN}✓${NC} $EDGE_DIR/ structure created"

# ── Generate secrets ──────────────────────────────────────────────────────────
WEBUI_SECRET=$(openssl rand -hex 32)
GRAFANA_PASS=$(openssl rand -base64 16 | tr -dc 'a-zA-Z0-9' | head -c 16)

# ── Write docker-compose.yml ──────────────────────────────────────────────────
echo -e "${YELLOW}▸${NC} Writing docker-compose.yml..."
cat > "$EDGE_DIR/docker-compose.yml" << COMPOSE
version: '3.8'

services:
  ollama:
    image: ollama/ollama:latest
    container_name: etheros-ollama
    restart: unless-stopped
    volumes:
      - ./data/ollama:/root/.ollama
    networks:
      - etheros-net
    ports:
      - "127.0.0.1:11434:11434"
    environment:
      - OLLAMA_KEEP_ALIVE=24h
      - OLLAMA_NUM_PARALLEL=2

  open-webui:
    image: ghcr.io/open-webui/open-webui:main
    container_name: etheros-open-webui
    restart: unless-stopped
    depends_on:
      - ollama
    volumes:
      - ./data/open-webui:/app/backend/data
    networks:
      - etheros-net
    ports:
      - "127.0.0.1:3000:8080"
    environment:
      - OLLAMA_BASE_URL=http://etheros-ollama:11434
      - WEBUI_SECRET_KEY=${WEBUI_SECRET}
      - ENABLE_SIGNUP=false
      - ENABLE_API_KEY=true
      - WEBUI_URL=https://${DOMAIN}
      - WEBUI_ISP_TENANT=${ISP_SLUG}
      - DEFAULT_LOCALE=en

  nginx:
    image: nginx:alpine
    container_name: etheros-nginx
    restart: unless-stopped
    depends_on:
      - open-webui
    volumes:
      - ./nginx/conf.d:/etc/nginx/conf.d:ro
      - /etc/letsencrypt:/etc/letsencrypt:ro
      - /var/www/html:/var/www/html:ro
    networks:
      - etheros-net
    ports:
      - "80:80"
      - "443:443"
      - "8443:8443"

  model-loader:
    image: curlimages/curl:latest
    container_name: etheros-model-loader
    restart: "no"
    depends_on:
      - ollama
    networks:
      - etheros-net
    entrypoint: ["/bin/sh", "-c"]
    command:
      - |
        echo "Waiting for Ollama..."
        for i in \$(seq 1 30); do
          if curl -sf http://etheros-ollama:11434/api/tags > /dev/null 2>&1; then
            echo "Ollama ready. Pulling ${MODEL}..."
            curl -sf -X POST http://etheros-ollama:11434/api/pull \
              -d '{"name":"${MODEL}"}' > /dev/null
            echo "Model ${MODEL} ready."
            exit 0
          fi
          echo "Attempt \$i/30 — waiting 10s..."
          sleep 10
        done
        echo "Ollama not ready after 5 min. Pull model manually."
        exit 1

  prometheus:
    image: prom/prometheus:latest
    container_name: etheros-prometheus
    restart: unless-stopped
    volumes:
      - ./data/prometheus:/prometheus
    networks:
      - etheros-net
    ports:
      - "127.0.0.1:9090:9090"
    command:
      - '--config.file=/etc/prometheus/prometheus.yml'
      - '--storage.tsdb.path=/prometheus'
      - '--storage.tsdb.retention.time=15d'

  grafana:
    image: grafana/grafana:latest
    container_name: etheros-grafana
    restart: unless-stopped
    depends_on:
      - prometheus
    volumes:
      - ./data/grafana:/var/lib/grafana
    networks:
      - etheros-net
    ports:
      - "127.0.0.1:3001:3000"
    environment:
      - GF_SECURITY_ADMIN_PASSWORD=${GRAFANA_PASS}
      - GF_USERS_ALLOW_SIGN_UP=false
      - GF_SERVER_ROOT_URL=https://${DOMAIN}/grafana/

networks:
  etheros-net:
    driver: bridge
COMPOSE
echo -e "  ${GREEN}✓${NC} docker-compose.yml written"

# ── Write nginx base config ───────────────────────────────────────────────────
echo -e "${YELLOW}▸${NC} Writing nginx base config..."
cat > "$EDGE_DIR/nginx/conf.d/etheros-edge.conf" << NGINX
# EtherOS Edge Node — ${DOMAIN}
# Auto-generated by bootstrap.sh

upstream openwebui {
    server etheros-open-webui:8080;
}

# HTTP — redirect to HTTPS + certbot webroot
server {
    listen 80;
    server_name ${DOMAIN};

    location /.well-known/acme-challenge/ {
        root /var/www/html;
    }

    location / {
        return 301 https://\$host\$request_uri;
    }
}

# HTTPS — main site
server {
    listen 443 ssl http2;
    server_name ${DOMAIN};

    ssl_certificate     /etc/letsencrypt/live/${DOMAIN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${DOMAIN}/privkey.pem;
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_ciphers         HIGH:!aNULL:!MD5;
    ssl_session_cache   shared:SSL:10m;

    client_max_body_size 100M;
    proxy_read_timeout   300s;

    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;
    add_header X-ISP-Tenant "${ISP_SLUG}" always;

    location /api/ {
        proxy_pass         http://openwebui/api/;
        proxy_set_header   Host \$host;
        proxy_set_header   X-Real-IP \$remote_addr;
        proxy_set_header   X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto \$scheme;
        proxy_http_version 1.1;
        proxy_set_header   Upgrade \$http_upgrade;
        proxy_set_header   Connection "upgrade";
    }

    location /ws/ {
        proxy_pass         http://openwebui/ws/;
        proxy_http_version 1.1;
        proxy_set_header   Upgrade \$http_upgrade;
        proxy_set_header   Connection "upgrade";
        proxy_set_header   Host \$host;
        proxy_set_header   X-Real-IP \$remote_addr;
        proxy_set_header   X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto \$scheme;
        proxy_read_timeout 86400;
    }

    location / {
        proxy_pass         http://openwebui;
        proxy_set_header   Host \$host;
        proxy_set_header   X-Real-IP \$remote_addr;
        proxy_set_header   X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto \$scheme;
        proxy_http_version 1.1;
        proxy_set_header   Upgrade \$http_upgrade;
        proxy_set_header   Connection "upgrade";
    }

    location /health {
        return 200 '{"status":"ok","tenant":"${ISP_SLUG}","domain":"${DOMAIN}"}';
        add_header Content-Type application/json;
    }
}
NGINX
echo -e "  ${GREEN}✓${NC} nginx config written"

# ── Write temporary HTTP-only nginx config for certbot ────────────────────────
cat > "$EDGE_DIR/nginx/conf.d/etheros-http-only.conf" << NGINX_HTTP
server {
    listen 80;
    server_name ${DOMAIN};
    location /.well-known/acme-challenge/ {
        root /var/www/html;
    }
    location / {
        return 200 'EtherOS bootstrapping...';
        add_header Content-Type text/plain;
    }
}
NGINX_HTTP

# ── Write ISP config ──────────────────────────────────────────────────────────
echo -e "${YELLOW}▸${NC} Writing ISP tenant config..."
cat > "$EDGE_DIR/isp-config/${ISP_SLUG}.json" << JSON
{
  "slug": "${ISP_SLUG}",
  "name": "${ISP_NAME}",
  "domain": "${DOMAIN}",
  "accent_color": "${ACCENT}",
  "primary_color": "#0D1B2A",
  "support_email": "${EMAIL}",
  "admin_email": "${EMAIL}",
  "model": "${MODEL}",
  "plan_personal_price": 49,
  "plan_professional_price": 99,
  "max_terminals": 500,
  "bootstrapped_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
JSON
echo -e "  ${GREEN}✓${NC} ISP config: isp-config/${ISP_SLUG}.json"

# ── Install Sprint 3B management scripts ─────────────────────────────────────
echo -e "${YELLOW}▸${NC} Installing ISP management scripts..."

# nginx tenant vhost template
cat > "$EDGE_DIR/nginx/tenant-vhost.conf.template" << 'TMPL'
upstream openwebui___SLUG__ {
    server etheros-open-webui:8080;
}
server {
    listen 443 ssl http2;
    server_name __DOMAIN__;
    ssl_certificate     /etc/letsencrypt/live/__DOMAIN__/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/__DOMAIN__/privkey.pem;
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_ciphers         HIGH:!aNULL:!MD5;
    client_max_body_size 100M;
    proxy_read_timeout   300s;
    add_header X-ISP-Tenant "__SLUG__" always;
    add_header X-ISP-Name "__ISP_NAME__" always;
    add_header X-ISP-Accent "__ACCENT_COLOR__" always;
    location / {
        proxy_pass http://openwebui___SLUG__;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
    }
    location /health {
        return 200 '{"status":"ok","tenant":"__SLUG__"}';
        add_header Content-Type application/json;
    }
}
server {
    listen 80;
    server_name __DOMAIN__;
    return 301 https://$host$request_uri;
}
TMPL

# add-isp-tenant.sh
cat > "$EDGE_DIR/add-isp-tenant.sh" << 'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
EDGE_DIR="/opt/etheros-edge"
GREEN='\033[0;32m'; CYAN='\033[0;36m'; YELLOW='\033[1;33m'; BOLD='\033[1m'; RED='\033[0;31m'; NC='\033[0m'
SLUG=""; NAME=""; DOMAIN=""; ACCENT="#00C2CB"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --slug) SLUG="$2"; shift 2 ;; --name) NAME="$2"; shift 2 ;;
    --domain) DOMAIN="$2"; shift 2 ;; --accent) ACCENT="$2"; shift 2 ;;
    *) echo "Usage: $0 --slug <slug> --name <name> --domain <domain> [--accent <hex>]"; exit 1 ;;
  esac
done
[[ -z "$SLUG" || -z "$NAME" || -z "$DOMAIN" ]] && { echo -e "${RED}--slug, --name, --domain required${NC}"; exit 1; }
[[ ! "$SLUG" =~ ^[a-z0-9-]+$ ]] && { echo -e "${RED}slug must be lowercase letters/numbers/hyphens${NC}"; exit 1; }
echo -e "${CYAN}${BOLD}━━━ Adding ISP Tenant: ${SLUG} ━━━${NC}"
cat > "$EDGE_DIR/isp-config/${SLUG}.json" << JSONEOF
{"slug":"${SLUG}","name":"${NAME}","domain":"${DOMAIN}","accent_color":"${ACCENT}","primary_color":"#0D1B2A","support_email":"support@${DOMAIN#edge.}","max_terminals":500}
JSONEOF
sed -e "s|__DOMAIN__|${DOMAIN}|g" -e "s|__SLUG__|${SLUG}|g" \
    -e "s|__ISP_NAME__|${NAME}|g" -e "s|__ACCENT_COLOR__|${ACCENT}|g" \
    "$EDGE_DIR/nginx/tenant-vhost.conf.template" > "$EDGE_DIR/nginx/conf.d/${SLUG}.conf"
docker exec etheros-nginx nginx -s reload
echo -e "${GREEN}✓ Tenant '${SLUG}' added. DNS: ${DOMAIN} → $(curl -s ifconfig.me)${NC}"
echo "Next: certbot certonly --standalone -d ${DOMAIN} && docker exec etheros-nginx nginx -s reload"
SCRIPT
chmod +x "$EDGE_DIR/add-isp-tenant.sh"

# list-isp-tenants.sh
cat > "$EDGE_DIR/list-isp-tenants.sh" << 'SCRIPT'
#!/usr/bin/env bash
EDGE_DIR="/opt/etheros-edge"
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
echo -e "${CYAN}${BOLD}━━━ EtherOS ISP Tenants ━━━${NC}"
printf "%-20s %-25s %-35s\n" "SLUG" "NAME" "DOMAIN"
printf "%-20s %-25s %-35s\n" "────────────────────" "─────────────────────────" "───────────────────────────────────"
shopt -s nullglob
for f in "$EDGE_DIR/isp-config/"*.json; do
  slug=$(python3 -c "import json; d=json.load(open('$f')); print(d.get('slug','?'))")
  name=$(python3 -c "import json; d=json.load(open('$f')); print(d.get('name','?'))")
  domain=$(python3 -c "import json; d=json.load(open('$f')); print(d.get('domain','?'))")
  printf "%-20s %-25s %-35s\n" "$slug" "$name" "$domain"
done
SCRIPT
chmod +x "$EDGE_DIR/list-isp-tenants.sh"

echo -e "  ${GREEN}✓${NC} Management scripts installed"

# ── Set up certbot webroot dir ────────────────────────────────────────────────
mkdir -p /var/www/html/.well-known/acme-challenge

# ── Start nginx for certbot (HTTP only first) ─────────────────────────────────
echo ""
echo -e "${YELLOW}▸${NC} Starting nginx (HTTP-only mode for cert issuance)..."
# Remove full HTTPS config temporarily so nginx starts without cert
mv "$EDGE_DIR/nginx/conf.d/etheros-edge.conf" "$EDGE_DIR/nginx/conf.d/etheros-edge.conf.disabled"
docker run --rm -d \
  --name etheros-nginx-bootstrap \
  -p 80:80 \
  -v "$EDGE_DIR/nginx/conf.d:/etc/nginx/conf.d:ro" \
  -v /var/www/html:/var/www/html:ro \
  nginx:alpine > /dev/null 2>&1 || true
sleep 2

# ── Issue TLS cert ────────────────────────────────────────────────────────────
if [[ "$SKIP_CERT" == "false" ]]; then
  echo -e "${YELLOW}▸${NC} Issuing Let's Encrypt certificate for ${DOMAIN}..."
  if certbot certonly \
    --webroot -w /var/www/html \
    -d "$DOMAIN" \
    --email "$EMAIL" \
    --agree-tos \
    --non-interactive \
    --quiet 2>&1; then
    echo -e "  ${GREEN}✓${NC} TLS cert issued: /etc/letsencrypt/live/${DOMAIN}/"
    CERT_OK=true
  else
    echo -e "  ${YELLOW}⚠${NC}  Cert issuance failed — DNS may not be propagated yet."
    echo -e "     Run manually later: certbot certonly --webroot -w /var/www/html -d ${DOMAIN} --email ${EMAIL} --agree-tos --non-interactive"
    CERT_OK=false
    # Create self-signed fallback so nginx can start
    mkdir -p "/etc/letsencrypt/live/${DOMAIN}"
    openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
      -keyout "/etc/letsencrypt/live/${DOMAIN}/privkey.pem" \
      -out "/etc/letsencrypt/live/${DOMAIN}/fullchain.pem" \
      -subj "/CN=${DOMAIN}" > /dev/null 2>&1
    echo -e "  ${YELLOW}⚠${NC}  Self-signed cert created as fallback (browser will show warning)"
  fi

  # Set up renewal hook
  cat > /etc/letsencrypt/renewal-hooks/post/etheros-nginx-reload.sh << 'HOOK'
#!/bin/bash
docker exec etheros-nginx nginx -s reload
HOOK
  chmod +x /etc/letsencrypt/renewal-hooks/post/etheros-nginx-reload.sh
  echo -e "  ${GREEN}✓${NC} Cert renewal hook installed"
fi

# Stop bootstrap nginx, restore full config
docker stop etheros-nginx-bootstrap > /dev/null 2>&1 || true
mv "$EDGE_DIR/nginx/conf.d/etheros-edge.conf.disabled" "$EDGE_DIR/nginx/conf.d/etheros-edge.conf"
rm -f "$EDGE_DIR/nginx/conf.d/etheros-http-only.conf"

# ── Start the full stack ──────────────────────────────────────────────────────
echo ""
echo -e "${YELLOW}▸${NC} Starting EtherOS stack (this takes 2-3 minutes)..."
cd "$EDGE_DIR"
docker compose pull --quiet 2>/dev/null || true
docker compose up -d --remove-orphans

echo -e "  ${GREEN}✓${NC} Stack started. Waiting for services..."

# ── Wait for Open WebUI to be ready ──────────────────────────────────────────
echo -e "${YELLOW}▸${NC} Waiting for Open WebUI to be ready..."
for i in $(seq 1 30); do
  if curl -sf http://localhost:3000/health > /dev/null 2>&1; then
    echo -e "  ${GREEN}✓${NC} Open WebUI is ready"
    break
  fi
  echo -e "  Attempt $i/30 — waiting 10s..."
  sleep 10
done

# ── Create admin account ──────────────────────────────────────────────────────
echo -e "${YELLOW}▸${NC} Setting up admin account..."
ADMIN_PASS=$(openssl rand -base64 16 | tr -dc 'a-zA-Z0-9' | head -c 16)
SIGNUP_RESP=$(curl -sf -X POST http://localhost:3000/api/v1/auths/signup \
  -H "Content-Type: application/json" \
  -d "{\"name\":\"EtherOS Admin\",\"email\":\"${EMAIL}\",\"password\":\"${ADMIN_PASS}\"}" 2>/dev/null || echo "exists")

if echo "$SIGNUP_RESP" | grep -q "token\|id"; then
  echo -e "  ${GREEN}✓${NC} Admin account created"
  ADMIN_CREATED=true
else
  echo -e "  ${YELLOW}⚠${NC}  Admin account may already exist — skipping"
  ADMIN_CREATED=false
fi

# ── Pull AI model ─────────────────────────────────────────────────────────────
if [[ "$SKIP_MODEL" == "false" ]]; then
  echo -e "${YELLOW}▸${NC} Pulling AI model: ${MODEL} (this may take several minutes)..."
  docker exec etheros-ollama ollama pull "$MODEL" && \
    echo -e "  ${GREEN}✓${NC} Model ${MODEL} ready" || \
    echo -e "  ${YELLOW}⚠${NC}  Model pull failed — run: docker exec etheros-ollama ollama pull ${MODEL}"
fi

# ── Write credentials file ────────────────────────────────────────────────────
CREDS_FILE="$EDGE_DIR/.bootstrap-credentials"
cat > "$CREDS_FILE" << CREDS
# EtherOS Bootstrap Credentials — $(date)
# KEEP THIS FILE SECURE — store in your password manager

ISP_SLUG=${ISP_SLUG}
ISP_NAME=${ISP_NAME}
DOMAIN=${DOMAIN}
MODEL=${MODEL}

WEBUI_URL=https://${DOMAIN}
WEBUI_ADMIN_EMAIL=${EMAIL}
$(if [[ "$ADMIN_CREATED" == "true" ]]; then echo "WEBUI_ADMIN_PASSWORD=${ADMIN_PASS}"; else echo "WEBUI_ADMIN_PASSWORD=<use existing password>"; fi)

GRAFANA_URL=http://$(curl -s ifconfig.me):3001
GRAFANA_USER=admin
GRAFANA_PASSWORD=${GRAFANA_PASS}

WEBUI_SECRET_KEY=${WEBUI_SECRET}
CREDS
chmod 600 "$CREDS_FILE"

# ── Final status check ────────────────────────────────────────────────────────
echo ""
echo -e "${YELLOW}▸${NC} Running final health checks..."
sleep 5
CONTAINERS=$(docker compose -f "$EDGE_DIR/docker-compose.yml" ps --format json 2>/dev/null | python3 -c "
import json,sys
data=sys.stdin.read().strip()
if not data: print('0 running'); exit()
try:
  items = json.loads(data) if data.startswith('[') else [json.loads(l) for l in data.splitlines() if l.strip()]
  running = sum(1 for i in items if i.get('State')=='running' or i.get('Status','').startswith('Up'))
  print(f'{running} running')
except: print('unknown')
" 2>/dev/null || echo "check manually")

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}${BOLD}╔══════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}${BOLD}║     EtherOS Edge Node — Bootstrap Complete ✓         ║${NC}"
echo -e "${GREEN}${BOLD}╚══════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${BOLD}  ISP:        ${CYAN}${ISP_NAME}${NC}"
echo -e "${BOLD}  Domain:     ${CYAN}https://${DOMAIN}${NC}"
echo -e "${BOLD}  Model:      ${CYAN}${MODEL}${NC}"
echo -e "${BOLD}  Containers: ${CYAN}${CONTAINERS}${NC}"
echo ""
echo -e "${BOLD}  Credentials saved to:${NC} ${CREDS_FILE}"
echo -e "  ${YELLOW}cat ${CREDS_FILE}${NC}"
echo ""
echo -e "${BOLD}  Quick commands:${NC}"
echo -e "  ${CYAN}cd /opt/etheros-edge${NC}"
echo -e "  ${CYAN}docker compose ps${NC}              — container status"
echo -e "  ${CYAN}docker compose logs -f${NC}         — live logs"
echo -e "  ${CYAN}./list-isp-tenants.sh${NC}          — show tenants"
echo -e "  ${CYAN}./add-isp-tenant.sh --help${NC}     — add new ISP"
echo ""
if [[ "${SKIP_CERT}" == "false" && "${CERT_OK:-false}" == "false" ]]; then
  echo -e "${YELLOW}  ⚠  TLS CERT PENDING — run when DNS is ready:${NC}"
  echo -e "  certbot certonly --webroot -w /var/www/html -d ${DOMAIN} --email ${EMAIL} --agree-tos --non-interactive"
  echo -e "  docker exec etheros-nginx nginx -s reload"
  echo ""
fi
echo -e "${CYAN}  Docs: https://github.com/FGN2025/etheros-edge-deploy${NC}"
echo ""
