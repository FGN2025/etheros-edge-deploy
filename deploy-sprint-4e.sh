#!/usr/bin/env bash
# ============================================================
#  EtherOS — Sprint 4E Deploy: Blacknut Gaming Integration
#  Run as root on the VPS (srv1491974 / 72.62.160.72)
# ============================================================
set -euo pipefail

REPO_RAW="https://raw.githubusercontent.com/FGN2025/etheros-edge-deploy/main"
DEPLOY_DIR="/opt/etheros-edge"
STATIC_DIR="$DEPLOY_DIR/static/isp-portal"
BACKEND_DIR="$DEPLOY_DIR/backends/isp-portal"

echo "======================================================"
echo " EtherOS Sprint 4E — Blacknut Gaming Integration"
echo "======================================================"

# ── 1. Backend: pull updated server.js ────────────────────
echo ""
echo "[1/3] Updating ISP portal backend (server.js)..."
curl -fsSL "$REPO_RAW/backends/isp-portal/server.js" \
  -o "$BACKEND_DIR/server.js"
echo "  ✓ server.js updated (Blacknut entitlement + session polling)"

# ── 2. Frontend: pull new bundles ─────────────────────────
echo ""
echo "[2/3] Updating ISP portal frontend bundles..."

curl -fsSL "$REPO_RAW/static/isp-portal/index.html" \
  -o "$STATIC_DIR/index.html"

rm -f "$STATIC_DIR/assets/"*.js "$STATIC_DIR/assets/"*.css

curl -fsSL "$REPO_RAW/static/isp-portal/assets/index-C3FXYsfE.js" \
  -o "$STATIC_DIR/assets/index-C3FXYsfE.js"
curl -fsSL "$REPO_RAW/static/isp-portal/assets/index-bp47pfo3.css" \
  -o "$STATIC_DIR/assets/index-bp47pfo3.css"

echo "  ✓ Frontend bundles updated"

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
echo "Verifying endpoints..."
CFG=$(curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:3010/api/terminal/config)
echo "  /api/terminal/config → HTTP $CFG"
BN=$(curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:3010/api/services/blacknut/status)
echo "  /api/services/blacknut/status → HTTP $BN"

echo ""
echo "======================================================"
echo " Sprint 4E deploy complete!"
echo ""
echo " What's new:"
echo "   ✓ Plan entitlement check — gaming blocked if plan not entitled"
echo "   ✓ ISP admin sets which plans get gaming (personal/pro/charter)"
echo "   ✓ GamingTile shows 'Included' or 'Upgrade required' badge"
echo "   ✓ Dedicated GamingScreen with genre filter + stub game catalog"
echo "   ✓ Session launch → opens Blacknut in new tab"
echo "   ✓ Session expiry countdown in header"
echo "   ✓ 'Return to Game' button when session is active"
echo "   ✓ Session status polling endpoint ready for live API"
echo "   ✓ Settings: Gaming Access plan checkboxes"
echo "   ✓ blacknutGamingPlans saved to isp-settings.json"
echo "   ✓ terminal/config returns blacknutGamingPlans to terminal"
echo ""
echo " To go live when Blacknut keys arrive:"
echo "   Settings → Cloud Services → Enter Partner ID + API Key → Save"
echo "   (No redeployment needed — activates immediately)"
echo ""
echo " Live: https://edge.etheros.ai/isp-portal/#/terminal"
echo " Admin: https://edge.etheros.ai/isp-portal/#/settings"
echo "======================================================"
