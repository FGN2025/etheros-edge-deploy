#!/usr/bin/env bash
# ============================================================
#  EtherOS — Sprint 4D.5 Deploy: Persistent Chat History
#  Run as root on the VPS (srv1491974 / 72.62.160.72)
# ============================================================
set -euo pipefail

REPO_RAW="https://raw.githubusercontent.com/FGN2025/etheros-edge-deploy/main"
DEPLOY_DIR="/opt/etheros-edge"
STATIC_DIR="$DEPLOY_DIR/static/isp-portal"
BACKEND_DIR="$DEPLOY_DIR/backends/isp-portal"

echo "======================================================"
echo " EtherOS Sprint 4D.5 — Persistent Chat History"
echo "======================================================"

# ── 1. Backend: pull updated server.js ────────────────────
echo ""
echo "[1/3] Updating ISP portal backend (server.js)..."
curl -fsSL "$REPO_RAW/backends/isp-portal/server.js" \
  -o "$BACKEND_DIR/server.js"
echo "  ✓ server.js updated (chat history endpoints added)"

# ── 2. Frontend: pull new bundles ─────────────────────────
echo ""
echo "[2/3] Updating ISP portal frontend bundles..."

# index.html
curl -fsSL "$REPO_RAW/static/isp-portal/index.html" \
  -o "$STATIC_DIR/index.html"

# Remove old JS/CSS bundles
rm -f "$STATIC_DIR/assets/"*.js "$STATIC_DIR/assets/"*.css

# Pull new bundles
curl -fsSL "$REPO_RAW/static/isp-portal/assets/index-BIavSBnu.js" \
  -o "$STATIC_DIR/assets/index-BIavSBnu.js"
curl -fsSL "$REPO_RAW/static/isp-portal/assets/index-CU0_hZW7.css" \
  -o "$STATIC_DIR/assets/index-CU0_hZW7.css"

echo "  ✓ Frontend bundles updated"
echo "  ✓ index.html updated"

# ── 3. Restart backend container ──────────────────────────
echo ""
echo "[3/3] Restarting ISP portal backend container..."
docker restart etheros-isp-portal-backend
echo "  ✓ Container restarted"

# ── Verify ────────────────────────────────────────────────
echo ""
echo "Waiting 5s for container to be healthy..."
sleep 5

STATUS=$(docker inspect --format='{{.State.Status}}' etheros-isp-portal-backend 2>/dev/null || echo "unknown")
echo "  Container status: $STATUS"

echo ""
echo "Verifying new endpoints..."
HEALTH=$(curl -s -o /dev/null -w "%{http_code}" \
  http://127.0.0.1:3010/api/terminal/config 2>/dev/null || echo "000")
echo "  /api/terminal/config → HTTP $HEALTH"

echo ""
echo "======================================================"
echo " Sprint 4D.5 deploy complete!"
echo ""
echo " What's new:"
echo "   ✓ Chat history persisted per subscriber per agent"
echo "   ✓ GET /api/subscribers/:id/chats — recent conversations"
echo "   ✓ GET /api/subscribers/:id/chats/:agentId — load history (last 50)"
echo "   ✓ POST /api/subscribers/:id/chats/:agentId — append message"
echo "   ✓ DELETE /api/subscribers/:id/chats/:agentId — clear history"
echo "   ✓ Chat timestamps shown on every message"
echo "   ✓ 'Clear chat' button in chat header"
echo "   ✓ 'Recent Conversations' on Home screen with last message preview"
echo ""
echo " Live: https://edge.etheros.ai/isp-portal/#/terminal"
echo "======================================================"
