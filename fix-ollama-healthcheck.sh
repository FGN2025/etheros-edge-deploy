#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════════
# EtherOS — Fix Ollama healthcheck + bring up full stack
# Run on VPS as root: bash fix-ollama-healthcheck.sh
#
# Problem: Ollama fails its healthcheck because open-webui and nginx depend on
# it being "healthy" before they start. On a cold VPS Ollama takes 3-5 min to
# fully initialise, blowing the start_period.
#
# Fix: Remove hard healthcheck dependencies from open-webui and nginx so they
# start unconditionally. Ollama gets a generous start_period. Nginx will just
# retry the upstream until Ollama is ready.
# ═══════════════════════════════════════════════════════════════════════════════
set -euo pipefail

GREEN='\033[0;32m'; CYAN='\033[0;36m'; YELLOW='\033[1;33m'
BOLD='\033[1m'; RED='\033[0;31m'; NC='\033[0m'

E="/opt/etheros-edge"

echo -e "${CYAN}${BOLD}━━━ EtherOS — Fix Ollama + Full Stack Restart ━━━${NC}"
echo ""

# ── 1. Write updated docker-compose.yml ──────────────────────────────────────
# Key changes vs previous:
#   - Ollama start_period: 300s (5 min), retries: 10
#   - open-webui depends_on ollama with condition: service_started (not healthy)
#   - nginx depends_on open-webui + backends with condition: service_started
#   - isp-portal-backend and marketplace-backend have NO dependency on ollama
echo -e "${YELLOW}▸${NC} Writing updated docker-compose.yml..."
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

  # ── Ollama ─────────────────────────────────────────────────────────────────
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
      timeout: 15s
      retries: 10
      start_period: 300s

  # ── Model loader ───────────────────────────────────────────────────────────
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

  # ── Open WebUI — starts as soon as Ollama container is running (not healthy)
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
        condition: service_started
    healthcheck:
      test: ["CMD","curl","-sf","http://localhost:8080/health"]
      interval: 30s
      timeout: 10s
      retries: 10
      start_period: 120s

  # ── ISP Portal backend ─────────────────────────────────────────────────────
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
    healthcheck:
      test: ["CMD","wget","-qO-","http://localhost:3010/health"]
      interval: 15s
      timeout: 5s
      retries: 5
      start_period: 20s

  # ── Marketplace backend ────────────────────────────────────────────────────
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
    healthcheck:
      test: ["CMD","wget","-qO-","http://localhost:3011/health"]
      interval: 15s
      timeout: 5s
      retries: 5
      start_period: 20s

  # ── Nginx — starts as soon as backends are started (not healthy) ───────────
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
    depends_on:
      open-webui:
        condition: service_started
      isp-portal-backend:
        condition: service_started
      marketplace-backend:
        condition: service_started

  # ── Prometheus ─────────────────────────────────────────────────────────────
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

  # ── Grafana ────────────────────────────────────────────────────────────────
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
echo -e "  ${GREEN}✓${NC} docker-compose.yml written"

# ── 2. Stop everything cleanly ────────────────────────────────────────────────
echo -e "${YELLOW}▸${NC} Stopping all containers..."
cd "$E"
docker compose down --remove-orphans 2>&1 | tail -5
echo -e "  ${GREEN}✓${NC} All containers stopped"

# ── 3. Start backends + nginx first (no Ollama dependency) ───────────────────
echo -e "${YELLOW}▸${NC} Starting ISP Portal backend..."
docker compose up -d isp-portal-backend marketplace-backend
sleep 3

echo -e "${YELLOW}▸${NC} Starting Ollama (background, takes ~2-3 min on cold start)..."
docker compose up -d ollama
echo -e "  ${GREEN}✓${NC} Ollama started (will become healthy in ~2-3 min)"

echo -e "${YELLOW}▸${NC} Starting Open WebUI..."
docker compose up -d open-webui
sleep 3

echo -e "${YELLOW}▸${NC} Starting Nginx..."
docker compose up -d nginx
sleep 2

echo -e "${YELLOW}▸${NC} Starting Prometheus + Grafana..."
docker compose up -d prometheus grafana
echo -e "  ${GREEN}✓${NC} All services started"

# ── 4. Quick health checks ────────────────────────────────────────────────────
echo ""
echo -e "${YELLOW}▸${NC} Checking critical backends (5s)..."
sleep 5

check() {
    local label="$1" url="$2"
    local status
    status=$(curl -s -o /tmp/r.txt -w "%{http_code}" "$url" 2>/dev/null || echo "000")
    local body; body=$(head -c 100 /tmp/r.txt 2>/dev/null)
    if [[ "$status" == "200" ]]; then
        echo -e "  ${GREEN}✓${NC} [$status] $label"
    else
        echo -e "  ${RED}✗${NC}  [$status] $label — ${body}"
    fi
}

check "ISP Portal /api/tenant"   "http://127.0.0.1:3010/api/tenant"
check "ISP Portal /health"       "http://127.0.0.1:3010/health"
check "Marketplace /health"      "http://127.0.0.1:3011/health"
check "Nginx (HTTP→HTTPS)"       "http://127.0.0.1:80/health"

echo ""
echo -e "${CYAN}Sprint 4A tenant response:${NC}"
curl -s http://127.0.0.1:3010/api/tenant 2>/dev/null | python3 -m json.tool 2>/dev/null \
  || curl -s http://127.0.0.1:3010/api/tenant

echo ""
echo -e "${GREEN}${BOLD}━━━ Stack is up ━━━${NC}"
echo -e "  ISP Portal:  https://edge.etheros.ai/isp-portal/"
echo -e "  Marketplace: https://edge.etheros.ai/marketplace/"
echo -e "  Open WebUI:  https://edge.etheros.ai/"
echo ""
echo -e "${YELLOW}Note:${NC} Ollama is still warming up. Open WebUI may show"
echo "  'connecting...' for 2-3 min — that's normal on a cold start."
echo ""
echo -e "Check all container states with: ${CYAN}docker compose -f $E/docker-compose.yml ps${NC}"
