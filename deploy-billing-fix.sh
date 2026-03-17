#!/usr/bin/env bash
# Fix: suppress misleading "Stripe key not configured" banner when key IS set
# curl -fsSL https://raw.githubusercontent.com/FGN2025/etheros-edge-deploy/main/deploy-billing-fix.sh | bash
set -euo pipefail
GREEN='\033[0;32m'; CYAN='\033[0;36m'; YELLOW='\033[1;33m'; BOLD='\033[1m'; NC='\033[0m'
REPO="https://raw.githubusercontent.com/FGN2025/etheros-edge-deploy/main"

echo -e "${CYAN}${BOLD}━━━ EtherOS — Billing Banner Fix ━━━${NC}"

# Pull patched JS bundle
echo -e "${YELLOW}▸${NC} Updating frontend bundle..."
curl -fsSL "$REPO/static/isp-portal/assets/index-B3Uy5dyE.js" \
  -o /opt/etheros-edge/static/isp-portal/assets/index-B3Uy5dyE.js
echo -e "  ${GREEN}✓${NC} Bundle updated"

# Pull updated billing.js route (adds hasStripeKey to /api/billing response)
echo -e "${YELLOW}▸${NC} Updating billing route..."
curl -fsSL "$REPO/backends/isp-portal/routes/billing.js" \
  -o /opt/etheros-edge/backends/isp-portal/routes/billing.js
echo -e "  ${GREEN}✓${NC} billing.js updated"

# Restart backend
echo -e "${YELLOW}▸${NC} Restarting backend..."
docker restart etheros-isp-portal-backend
sleep 5

# Verify
BILLING=$(curl -sf https://edge.etheros.ai/api/billing 2>/dev/null | python3 -c "import sys,json; d=json.load(sys.stdin); print(f'status={d.get(\"status\")}, hasStripeKey={d.get(\"hasStripeKey\")}')" 2>/dev/null || echo "error")
echo -e "  /api/billing → ${CYAN}$BILLING${NC}"

echo -e "${GREEN}${BOLD}━━━ Done — billing banner suppressed ━━━${NC}"
