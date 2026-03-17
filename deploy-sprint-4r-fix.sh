#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════════
# EtherOS — Sprint 4R fix: correct package.json + install deps
# Run on VPS: curl -fsSL https://raw.githubusercontent.com/FGN2025/etheros-edge-deploy/main/deploy-sprint-4r-fix.sh | bash
# ═══════════════════════════════════════════════════════════════════════════════
set -euo pipefail

GREEN='\033[0;32m'; CYAN='\033[0;36m'; YELLOW='\033[1;33m'; BOLD='\033[1m'; RED='\033[0;31m'; NC='\033[0m'
BACKEND="/opt/etheros-edge/backends/isp-portal"

echo -e "${CYAN}${BOLD}━━━ EtherOS Sprint 4R — Dependency Fix ━━━${NC}"
echo ""

# ── 1. Write correct package.json directly to the host mount ─────────────────
echo -e "${YELLOW}▸${NC} Writing corrected package.json..."
cat > "$BACKEND/package.json" << 'PKG'
{
  "name": "etheros-isp-portal-backend",
  "version": "2.0.0",
  "type": "commonjs",
  "scripts": { "start": "node server.js" },
  "dependencies": {
    "express": "^4.18.2",
    "cors": "^2.8.5",
    "stripe": "^14.0.0",
    "better-sqlite3": "^9.4.3",
    "resend": "^3.0.0"
  }
}
PKG
echo -e "  ${GREEN}✓${NC} package.json written (resend, not @resend/node)"

# ── 2. Install deps inside the container (reads the corrected file) ───────────
echo -e "${YELLOW}▸${NC} Installing dependencies inside container..."
docker exec etheros-isp-portal-backend sh -c "cd /app && npm install --omit=dev 2>&1"
echo -e "  ${GREEN}✓${NC} Dependencies installed"

# ── 3. Restart ────────────────────────────────────────────────────────────────
echo -e "${YELLOW}▸${NC} Restarting ISP portal backend..."
docker restart etheros-isp-portal-backend
sleep 5

# ── 4. Health check ───────────────────────────────────────────────────────────
HEALTH=$(curl -sf https://edge.etheros.ai/api/health 2>/dev/null || echo '{}')
echo -e "  Health: $HEALTH"

if echo "$HEALTH" | grep -q '"status":"ok"'; then
  echo -e "  ${GREEN}✓${NC} Health check passed"
else
  echo -e "  ${RED}✗${NC} Unexpected response — check logs:"
  echo -e "  docker logs etheros-isp-portal-backend --tail 50"
fi

# ── 5. Smoke tests ────────────────────────────────────────────────────────────
echo ""
echo -e "${YELLOW}▸${NC} Smoke tests..."
TENANT=$(curl -sf https://edge.etheros.ai/api/tenant 2>/dev/null | python3 -c "import sys,json; print(json.load(sys.stdin).get('name','?'))" 2>/dev/null || echo "?")
echo -e "  /api/tenant → ${CYAN}$TENANT${NC}"

DASH=$(curl -sf https://edge.etheros.ai/api/dashboard 2>/dev/null | python3 -c "import sys,json; d=json.load(sys.stdin); print(f'terminals={d.get(\"totalTerminals\",\"?\")}, subs={d.get(\"totalSubscribers\",\"?\")}') " 2>/dev/null || echo "?")
echo -e "  /api/dashboard → ${CYAN}$DASH${NC}"

VERIFY=$(curl -sf https://edge.etheros.ai/api/admin/verify -H "x-admin-token: test" 2>/dev/null | python3 -c "import sys,json; print(json.load(sys.stdin))" 2>/dev/null || echo "?")
echo -e "  /api/admin/verify → ${CYAN}$VERIFY${NC}"

echo ""
echo -e "${GREEN}${BOLD}━━━ Sprint 4R fix complete ━━━${NC}"
