#!/bin/bash
set -e

STATIC=/opt/etheros-edge/static/isp-portal/assets
NGINX=/opt/etheros-edge/nginx
BACKEND=/opt/etheros-edge/backends/isp-portal
RAW=https://raw.githubusercontent.com/FGN2025/etheros-edge-deploy/main

echo "=== Sprint 4C Deploy: Multi-Tenant ISP Isolation ==="

# ── 1. Frontend static bundle ────────────────────────────────────────────────
echo "[1/3] Updating frontend bundle..."
rm -f $STATIC/index-*.js $STATIC/index-*.css
curl -sSf "$RAW/static/isp-portal/assets/index-BXem4aNe.js"  -o $STATIC/index-BXem4aNe.js
curl -sSf "$RAW/static/isp-portal/assets/index-DQT8I1Wc.css" -o $STATIC/index-DQT8I1Wc.css
curl -sSf "$RAW/static/isp-portal/index.html"                 -o /opt/etheros-edge/static/isp-portal/index.html

echo "  Assets:"
ls $STATIC
echo "  index.html → $(grep -o 'index-[^\"]*' /opt/etheros-edge/static/isp-portal/index.html | tr '\n' ' ')"

# ── 2. Backend server.js ─────────────────────────────────────────────────────
echo "[2/3] Updating backend server.js..."
curl -sSf "$RAW/backends/isp-portal/server.js" -o $BACKEND/server.js
docker restart etheros-isp-portal-backend
echo "  Waiting for backend..."
sleep 3
STATUS=$(curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:3010/health 2>/dev/null || echo "000")
echo "  Backend health: HTTP $STATUS"

# ── 3. nginx tenant vhost template ──────────────────────────────────────────
echo "[3/3] Installing nginx vhost template..."
mkdir -p $NGINX
curl -sSf "$RAW/nginx/tenant-vhost.conf.template" -o $NGINX/tenant-vhost.conf.template
echo "  Template installed at $NGINX/tenant-vhost.conf.template"

echo ""
echo "=== Sprint 4C deployed successfully ==="
echo ""
echo "What's new:"
echo "  • Tenants page added to sidebar (/#/tenants)"
echo "  • New ISP sign-ups auto-spin a Docker container + nginx vhost"
echo "  • /api/billing/tenants now includes live container health"
echo "  • nginx/tenant-vhost.conf.template ready for per-ISP domains"
echo ""
echo "Open: https://edge.etheros.ai/isp-portal/#/tenants"
