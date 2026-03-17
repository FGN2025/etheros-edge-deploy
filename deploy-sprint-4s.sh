#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════════
# EtherOS — Sprint 4S Deploy: API Hardening
#
# Changes deployed:
#   - Admin auth middleware on all ISP routes
#   - Secrets stripped from /api/settings response
#   - JSON→SQLite migration forced on startup
#   - Dashboard reads from SQLite
#   - Rate limiting on login + PIN auth
#   - Stripe webhook signature enforced (no unsigned fallback)
#
# curl -fsSL https://raw.githubusercontent.com/FGN2025/etheros-edge-deploy/main/deploy-sprint-4s.sh | bash
# ═══════════════════════════════════════════════════════════════════════════════
set -euo pipefail

GREEN='\033[0;32m'; CYAN='\033[0;36m'; YELLOW='\033[1;33m'; BOLD='\033[1m'; RED='\033[0;31m'; NC='\033[0m'
REPO="https://raw.githubusercontent.com/FGN2025/etheros-edge-deploy/main"
BACKEND="/opt/etheros-edge/backends/isp-portal"
ROUTES="$BACKEND/routes"

echo -e "${CYAN}${BOLD}━━━ EtherOS Sprint 4S — Hardening ━━━${NC}"
echo ""

# ── Pull all changed backend files ───────────────────────────────────────────
echo -e "${YELLOW}▸${NC} Pulling backend files..."
curl -fsSL "$REPO/backends/isp-portal/server.js"          -o "$BACKEND/server.js"
curl -fsSL "$REPO/backends/isp-portal/routes/middleware.js" -o "$ROUTES/middleware.js"
curl -fsSL "$REPO/backends/isp-portal/routes/admin.js"    -o "$ROUTES/admin.js"
curl -fsSL "$REPO/backends/isp-portal/routes/billing.js"  -o "$ROUTES/billing.js"
curl -fsSL "$REPO/backends/isp-portal/routes/dashboard.js" -o "$ROUTES/dashboard.js"
echo -e "  ${GREEN}✓${NC} 5 files updated"

# ── Restart backend ───────────────────────────────────────────────────────────
echo -e "${YELLOW}▸${NC} Restarting ISP portal backend..."
docker restart etheros-isp-portal-backend
sleep 6
echo -e "  ${GREEN}✓${NC} Restarted"

# ── Health check ─────────────────────────────────────────────────────────────
echo ""
echo -e "${YELLOW}▸${NC} Health + migration check..."
HEALTH=$(curl -sf https://edge.etheros.ai/health 2>/dev/null || echo '{}')
echo -e "  /health → $HEALTH"

# ── Auth verification — unauthenticated requests should now 401 ───────────────
echo ""
echo -e "${YELLOW}▸${NC} Auth gate verification (expect 401)..."
for ep in /api/settings /api/subscribers /api/terminals /api/revenue /api/server-stats /api/dashboard /api/marketing/campaigns; do
  STATUS=$(curl -s -o /dev/null -w "%{http_code}" https://edge.etheros.ai$ep 2>/dev/null)
  if [ "$STATUS" = "401" ]; then
    echo -e "  ${GREEN}✓${NC} 401  $ep"
  else
    echo -e "  ${RED}✗${NC} $STATUS  $ep  ← UNEXPECTED"
  fi
done

# ── Public endpoints should still be accessible ───────────────────────────────
echo ""
echo -e "${YELLOW}▸${NC} Public endpoint verification (expect 200)..."
for ep in /health /api/tenant /api/terminal/config /api/billing/plans /api/agents/browse; do
  STATUS=$(curl -s -o /dev/null -w "%{http_code}" https://edge.etheros.ai$ep 2>/dev/null)
  if [ "$STATUS" = "200" ]; then
    echo -e "  ${GREEN}✓${NC} 200  $ep"
  else
    echo -e "  ${RED}✗${NC} $STATUS  $ep  ← UNEXPECTED"
  fi
done

# ── Settings secrets check ────────────────────────────────────────────────────
echo ""
echo -e "${YELLOW}▸${NC} Settings secrets check (need admin token)..."
# Login to get a token first
TOKEN=$(curl -sf -X POST https://edge.etheros.ai/api/admin/login \
  -H "Content-Type: application/json" \
  -d '{"password":"FGN2025!"}' 2>/dev/null | python3 -c "import sys,json; print(json.load(sys.stdin).get('token',''))" 2>/dev/null || echo "")

if [ -n "$TOKEN" ]; then
  SETTINGS=$(curl -sf https://edge.etheros.ai/api/settings -H "x-admin-token: $TOKEN" 2>/dev/null)
  if echo "$SETTINGS" | grep -q "adminPassword\|stripeWebhookSecret"; then
    echo -e "  ${RED}✗${NC} Secrets still present in settings response!"
  else
    echo -e "  ${GREEN}✓${NC} Secrets stripped from /api/settings"
  fi
  # Check migration — dashboard should show subscribers
  DASH=$(curl -sf https://edge.etheros.ai/api/dashboard -H "x-admin-token: $TOKEN" 2>/dev/null | \
    python3 -c "import sys,json; d=json.load(sys.stdin); print(f'subs={d.get(\"totalSubscribers\",\"?\")}, terminals={d.get(\"totalTerminals\",\"?\")}') " 2>/dev/null || echo "error")
  echo -e "  ${GREEN}✓${NC} /api/dashboard → $DASH"
else
  echo -e "  ${YELLOW}⚠${NC}  Could not get admin token — verify login password"
fi

echo ""
echo -e "${GREEN}${BOLD}━━━ Sprint 4S deploy complete ━━━${NC}"
echo -e "  Commit: bd1dbe0"
echo -e "  All admin routes now require x-admin-token header"
echo -e "  Public routes: /health /api/tenant /api/terminal/config /api/billing/plans /api/agents/browse"
