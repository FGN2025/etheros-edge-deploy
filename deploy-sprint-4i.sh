#!/usr/bin/env bash
# ============================================================
# deploy-sprint-4i.sh — EtherOS Sprint 4I: Marketing Console Core
# ============================================================
# Deploys:
#   1. Updated ISP portal bundle (index-sbjm9es3.js + index-CKqs-m0O.css)
#      with: Marketing nav item, /marketing route, Promo button on agent cards
#   2. Updated server.js with 13 marketing API endpoints
#   3. Creates marketing data directory + JSON files on VPS
# ============================================================
set -euo pipefail

REPO="https://raw.githubusercontent.com/FGN2025/etheros-edge-deploy/main"
BASE="/opt/etheros-edge"
ASSETS="$BASE/static/isp-portal/assets"
PORTAL_STATIC="$BASE/static/isp-portal"
BACKEND="$BASE/backends/isp-portal"
DATA="$BACKEND/data"

echo "╔══════════════════════════════════════════╗"
echo "║  EtherOS Sprint 4I — Marketing Console   ║"
echo "╚══════════════════════════════════════════╝"

# ── Step 1: Pull new JS bundle ─────────────────────────────
echo "[1/6] Pulling new JS bundle..."
curl -fsSL "$REPO/static/isp-portal/assets/index-sbjm9es3.js" \
     -o "$ASSETS/index-sbjm9es3.js"
echo "  ✓ index-sbjm9es3.js"

# ── Step 2: Pull new CSS bundle ────────────────────────────
echo "[2/6] Pulling new CSS bundle..."
curl -fsSL "$REPO/static/isp-portal/assets/index-CKqs-m0O.css" \
     -o "$ASSETS/index-CKqs-m0O.css"
echo "  ✓ index-CKqs-m0O.css"

# ── Step 3: Pull updated index.html ────────────────────────
echo "[3/6] Pulling updated index.html..."
curl -fsSL "$REPO/static/isp-portal/index.html" \
     -o "$PORTAL_STATIC/index.html"
echo "  ✓ index.html → references new bundle hashes"

# ── Step 4: Pull updated server.js ─────────────────────────
echo "[4/6] Pulling updated server.js (Sprint 4I marketing endpoints)..."
curl -fsSL "$REPO/backends/isp-portal/server.js" \
     -o "$BACKEND/server.js"
echo "  ✓ server.js"

# ── Step 5: Bootstrap marketing data files ─────────────────
echo "[5/6] Bootstrapping marketing data files..."
mkdir -p "$DATA"

[ -f "$DATA/marketing-campaigns.json" ] || echo "[]" > "$DATA/marketing-campaigns.json"
[ -f "$DATA/marketing-pages.json" ]    || echo "[]" > "$DATA/marketing-pages.json"
[ -f "$DATA/marketing-users.json" ]    || echo "[]" > "$DATA/marketing-users.json"
echo "  ✓ data/marketing-campaigns.json"
echo "  ✓ data/marketing-pages.json"
echo "  ✓ data/marketing-users.json"

# ── Step 6: Restart ISP portal backend ─────────────────────
echo "[6/6] Restarting ISP portal backend..."
docker restart etheros-isp-portal-backend
sleep 3
if docker ps --filter "name=etheros-isp-portal-backend" --filter "status=running" | grep -q etheros; then
  echo "  ✓ etheros-isp-portal-backend running"
else
  echo "  ✗ Container not running — check logs:"
  docker logs --tail 30 etheros-isp-portal-backend
  exit 1
fi

echo ""
echo "════════════════════════════════════════════"
echo "  Sprint 4I deploy complete ✓"
echo ""
echo "  New features:"
echo "    • Marketing nav item in sidebar"
echo "    • /marketing route (Campaigns | Web Pages | Team tabs)"
echo "    • Promo button on every agent card + table row"
echo "    • 13 marketing API endpoints live"
echo "    • marketing-campaigns/pages/users data files created"
echo ""
echo "  Test at: https://edge.etheros.ai/"
echo "════════════════════════════════════════════"
