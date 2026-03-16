#!/bin/bash
set -e

STATIC=/opt/etheros-edge/static/isp-portal/assets
BACKEND=/opt/etheros-edge/backends/isp-portal
NGINX_CONF=/opt/etheros-edge/nginx/conf.d/etheros-edge.conf
RAW=https://raw.githubusercontent.com/FGN2025/etheros-edge-deploy/main

echo "=== Sprint 4D Deploy: Subscriber Terminal ==="

# ── 1. Frontend bundle ───────────────────────────────────────────────────────
echo "[1/3] Updating frontend bundle..."
rm -f $STATIC/index-*.js $STATIC/index-*.css
curl -sSf "$RAW/static/isp-portal/assets/index-DuHeafTl.js"  -o $STATIC/index-DuHeafTl.js
curl -sSf "$RAW/static/isp-portal/assets/index-aK9y5GMF.css" -o $STATIC/index-aK9y5GMF.css
curl -sSf "$RAW/static/isp-portal/index.html"                 -o /opt/etheros-edge/static/isp-portal/index.html
echo "  $(ls $STATIC)"

# ── 2. Backend server.js ─────────────────────────────────────────────────────
echo "[2/3] Updating backend..."
curl -sSf "$RAW/backends/isp-portal/server.js" -o $BACKEND/server.js
docker restart etheros-isp-portal-backend
sleep 3
STATUS=$(curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:3010/health 2>/dev/null || echo "000")
echo "  Backend health: HTTP $STATUS"

# ── 3. Nginx (add chat/stream SSE location + reload) ─────────────────────────
echo "[3/3] Updating nginx config..."
curl -sSf "$RAW/nginx/conf.d/etheros-edge.conf" -o $NGINX_CONF
docker exec etheros-nginx nginx -t && docker exec etheros-nginx nginx -s reload
echo "  Nginx reloaded"

echo ""
echo "=== Sprint 4D deployed ==="
echo ""
echo "What's new:"
echo "  • Terminal PIN screen branded with ISP name/color from /api/terminal/config"
echo "  • Home screen: active agents, gaming tile, Open WebUI tile"
echo "  • Explore tab: browse + activate/deactivate agents up to plan limit"
echo "  • Inline AI chat with live Ollama streaming (falls back to Open WebUI)"
echo "  • New API: GET /api/agents/browse, GET /api/terminal/config, POST /api/chat/stream"
echo ""
echo "Test: https://edge.etheros.ai/isp-portal/#/terminal"
