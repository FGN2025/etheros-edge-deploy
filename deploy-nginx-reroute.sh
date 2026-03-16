#!/usr/bin/env bash
# ============================================================
# deploy-nginx-reroute.sh — Route / to ISP Portal, /chat/ to Open WebUI
# ============================================================
set -euo pipefail

REPO="https://raw.githubusercontent.com/FGN2025/etheros-edge-deploy/main"
NGINX_CONF="/opt/etheros-edge/nginx/conf.d/etheros.conf"

echo "╔══════════════════════════════════════════╗"
echo "║  EtherOS — nginx reroute to ISP Portal   ║"
echo "╚══════════════════════════════════════════╝"

# ── Step 1: Backup current config ──────────────────────────
echo "[1/4] Backing up current nginx config..."
cp "$NGINX_CONF" "${NGINX_CONF}.bak.$(date +%Y%m%d%H%M%S)"
echo "  ✓ Backup saved"

# ── Step 2: Pull new config ─────────────────────────────────
echo "[2/4] Pulling updated nginx config..."
curl -fsSL "$REPO/nginx/conf.d/etheros.conf" -o "$NGINX_CONF"
echo "  ✓ etheros.conf updated"

# ── Step 3: Test nginx config ───────────────────────────────
echo "[3/4] Testing nginx config..."
if docker exec etheros-nginx nginx -t 2>&1; then
  echo "  ✓ nginx config valid"
else
  echo "  ✗ Config invalid — restoring backup"
  cp "${NGINX_CONF}.bak."* "$NGINX_CONF" 2>/dev/null || true
  exit 1
fi

# ── Step 4: Reload nginx ────────────────────────────────────
echo "[4/4] Reloading nginx..."
docker exec etheros-nginx nginx -s reload
sleep 2
echo "  ✓ nginx reloaded"

echo ""
echo "════════════════════════════════════════════"
echo "  nginx reroute complete ✓"
echo ""
echo "  edge.etheros.ai/        → ISP Portal"
echo "  edge.etheros.ai/chat/   → Open WebUI (Ollama)"
echo "  edge.etheros.ai/api/    → ISP Portal backend"
echo "  edge.etheros.ai/marketplace/ → Marketplace"
echo "════════════════════════════════════════════"
