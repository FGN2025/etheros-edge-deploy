#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════════
# EtherOS — Sprint 4R Deploy
# SQLite migration + server.js modularization
#
# Run on VPS:
#   curl -fsSL https://raw.githubusercontent.com/FGN2025/etheros-edge-deploy/main/deploy-sprint-4r.sh | bash
# ═══════════════════════════════════════════════════════════════════════════════
set -euo pipefail

GREEN='\033[0;32m'; CYAN='\033[0;36m'; YELLOW='\033[1;33m'; BOLD='\033[1m'; RED='\033[0;31m'; NC='\033[0m'
REPO="https://raw.githubusercontent.com/FGN2025/etheros-edge-deploy/main"
BACKEND="/opt/etheros-edge/backends/isp-portal"
ROUTES="$BACKEND/routes"

echo -e "${CYAN}${BOLD}━━━ EtherOS Sprint 4R — Foundation Refactor ━━━${NC}"
echo ""

# ── 1. Create routes directory ────────────────────────────────────────────────
echo -e "${YELLOW}▸${NC} Creating routes directory..."
mkdir -p "$ROUTES"
echo -e "  ${GREEN}✓${NC} $ROUTES ready"

# ── 2. Pull all backend files ─────────────────────────────────────────────────
echo -e "${YELLOW}▸${NC} Pulling server.js + db.js..."
curl -fsSL "$REPO/backends/isp-portal/server.js"     -o "$BACKEND/server.js"
curl -fsSL "$REPO/backends/isp-portal/db.js"         -o "$BACKEND/db.js"
curl -fsSL "$REPO/backends/isp-portal/package.json"  -o "$BACKEND/package.json"
echo -e "  ${GREEN}✓${NC} Core files updated"

echo -e "${YELLOW}▸${NC} Pulling route modules..."
curl -fsSL "$REPO/backends/isp-portal/routes/terminals.js"   -o "$ROUTES/terminals.js"
curl -fsSL "$REPO/backends/isp-portal/routes/subscribers.js" -o "$ROUTES/subscribers.js"
curl -fsSL "$REPO/backends/isp-portal/routes/agents.js"      -o "$ROUTES/agents.js"
curl -fsSL "$REPO/backends/isp-portal/routes/marketing.js"   -o "$ROUTES/marketing.js"
curl -fsSL "$REPO/backends/isp-portal/routes/acquisition.js" -o "$ROUTES/acquisition.js"
curl -fsSL "$REPO/backends/isp-portal/routes/billing.js"     -o "$ROUTES/billing.js"
curl -fsSL "$REPO/backends/isp-portal/routes/admin.js"       -o "$ROUTES/admin.js"
curl -fsSL "$REPO/backends/isp-portal/routes/dashboard.js"   -o "$ROUTES/dashboard.js"
curl -fsSL "$REPO/backends/isp-portal/routes/chat.js"        -o "$ROUTES/chat.js"
echo -e "  ${GREEN}✓${NC} All 9 route modules deployed"

# ── 3. Install better-sqlite3 inside the container ───────────────────────────
echo -e "${YELLOW}▸${NC} Installing better-sqlite3 + any new deps..."
docker exec etheros-isp-portal-backend sh -c "cd /app && npm install --production 2>&1" || {
  echo -e "  ${YELLOW}⚠${NC}  npm install failed inside container — trying with npm ci fallback..."
  docker exec etheros-isp-portal-backend sh -c "cd /app && npm install better-sqlite3 stripe resend --save 2>&1"
}
echo -e "  ${GREEN}✓${NC} Dependencies installed"

# ── 4. Restart ISP portal backend ─────────────────────────────────────────────
echo -e "${YELLOW}▸${NC} Restarting ISP portal backend..."
docker restart etheros-isp-portal-backend
echo -e "  ${GREEN}✓${NC} Container restarted"

# ── 5. Wait and health check ──────────────────────────────────────────────────
echo -e "${YELLOW}▸${NC} Waiting for backend to come up..."
sleep 5

HEALTH=$(curl -sf https://edge.etheros.ai/api/health 2>/dev/null || echo '{}')
echo -e "  Health: $HEALTH"

if echo "$HEALTH" | grep -q '"status":"ok"'; then
  echo -e "  ${GREEN}✓${NC} Health check passed"
else
  echo -e "  ${RED}✗${NC} Health check returned unexpected response — check logs:"
  echo -e "  docker logs etheros-isp-portal-backend --tail 50"
fi

# ── 6. Quick smoke tests ───────────────────────────────────────────────────────
echo ""
echo -e "${YELLOW}▸${NC} Running smoke tests..."
TENANT=$(curl -sf https://edge.etheros.ai/api/tenant 2>/dev/null | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('name','?'))" 2>/dev/null || echo "?")
echo -e "  Tenant name: ${CYAN}$TENANT${NC}"

ACQ=$(curl -sf https://edge.etheros.ai/api/acquisition/pages 2>/dev/null | python3 -c "import sys,json; d=json.load(sys.stdin); print(f'[{len(d)} pages]')" 2>/dev/null || echo "?")
echo -e "  Acquisition pages: ${CYAN}$ACQ${NC}"

DASH=$(curl -sf https://edge.etheros.ai/api/dashboard 2>/dev/null | python3 -c "import sys,json; d=json.load(sys.stdin); print(f'terminals={d.get(\"totalTerminals\",\"?\")}, subs={d.get(\"totalSubscribers\",\"?\")}') " 2>/dev/null || echo "?")
echo -e "  Dashboard: ${CYAN}$DASH${NC}"

echo ""
echo -e "${GREEN}${BOLD}━━━ Sprint 4R deploy complete ━━━${NC}"
echo -e "  Commit: 8f989c8"
echo -e "  server.js:  180 lines  (was 2728)"
echo -e "  Routes:     9 modules, 2063 lines total"
echo -e "  db.js:      585 lines  (SQLite schema + migration)"
