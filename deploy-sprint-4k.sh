#!/bin/bash
# ============================================================
#  Sprint 4K — ISP Acquisition Tools  |  VPS Deploy Script
#  Commit: 6ea9814
# ============================================================
set -e

REPO="https://raw.githubusercontent.com/FGN2025/etheros-edge-deploy/main"
BASE="/opt/etheros-edge"

echo "=== Sprint 4K: ISP Acquisition Tools ==="

# ── 1. Pull updated server.js ────────────────────────────────
echo "[1/5] Updating backend server.js..."
curl -fsSL "$REPO/backends/isp-portal/server.js" \
  -o "$BASE/backends/isp-portal/server.js"

# ── 2. Pull nginx config ─────────────────────────────────────
echo "[2/5] Updating nginx config..."
curl -fsSL "$REPO/nginx/conf.d/etheros-edge.conf" \
  -o "$BASE/nginx/conf.d/etheros-edge.conf"

# ── 3. Pull new JS bundle ─────────────────────────────────────
echo "[3/5] Pulling new frontend bundle..."
curl -fsSL "$REPO/static/isp-portal/assets/index-B3Uy5dyE.js" \
  -o "$BASE/static/isp-portal/assets/index-B3Uy5dyE.js"

# ── 4. Pull new CSS bundle ────────────────────────────────────
echo "[4/5] Pulling new CSS bundle..."
curl -fsSL "$REPO/static/isp-portal/assets/index-DeLL5j9J.css" \
  -o "$BASE/static/isp-portal/assets/index-DeLL5j9J.css"

# ── 5. Update index.html ──────────────────────────────────────
echo "[5/5] Updating index.html..."
curl -fsSL "$REPO/static/isp-portal/index.html" \
  -o "$BASE/static/isp-portal/index.html"

# ── Clean up old Sprint 4H bundle ────────────────────────────
echo "[cleanup] Removing old Sprint 4H bundle files..."
rm -f "$BASE/static/isp-portal/assets/index-ButjmpYY.js"
rm -f "$BASE/static/isp-portal/assets/index-DLXiRb_O.css"

# ── Restart backend ───────────────────────────────────────────
echo "[restart] Restarting ISP portal backend..."
docker restart etheros-isp-portal-backend

# ── Reload nginx ──────────────────────────────────────────────
echo "[nginx] Testing & reloading nginx..."
docker exec etheros-nginx nginx -t && docker exec etheros-nginx nginx -s reload

echo ""
echo "=== Sprint 4K deployed! ==="
echo ""
echo "Verify:"
echo "  curl -s http://127.0.0.1:3010/health"
echo "  curl -s http://127.0.0.1:3010/api/acquisition/pages | head -c 100"
echo ""
echo "Live: https://edge.etheros.ai/  (Acquisition tab in sidebar)"
echo "Public landing pages: https://edge.etheros.ai/#/pages/<slug>"
