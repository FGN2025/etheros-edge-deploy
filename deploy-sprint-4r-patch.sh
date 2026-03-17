#!/usr/bin/env bash
# Sprint 4R hot-patch — fixes router mount paths in server.js, then restarts
# curl -fsSL https://raw.githubusercontent.com/FGN2025/etheros-edge-deploy/main/deploy-sprint-4r-patch.sh | bash
set -euo pipefail
GREEN='\033[0;32m'; CYAN='\033[0;36m'; YELLOW='\033[1;33m'; BOLD='\033[1m'; RED='\033[0;31m'; NC='\033[0m'
REPO="https://raw.githubusercontent.com/FGN2025/etheros-edge-deploy/main"
BACKEND="/opt/etheros-edge/backends/isp-portal"

echo -e "${CYAN}${BOLD}━━━ Sprint 4R — Route Mount Fix ━━━${NC}"

curl -fsSL "$REPO/backends/isp-portal/server.js" -o "$BACKEND/server.js"
echo -e "${GREEN}✓${NC} server.js updated"

docker restart etheros-isp-portal-backend
echo -e "${GREEN}✓${NC} Container restarted — waiting 6s..."
sleep 6

HEALTH=$(curl -sf https://edge.etheros.ai/health 2>/dev/null || echo '{}')
echo -e "  /health → $HEALTH"

TENANT=$(curl -sf https://edge.etheros.ai/api/tenant 2>/dev/null || echo '{}')
echo -e "  /api/tenant → $TENANT"

TERMS=$(curl -sf https://edge.etheros.ai/api/terminals 2>/dev/null | python3 -c "import sys,json; d=json.load(sys.stdin); print(f'[{len(d)} terminals]')" 2>/dev/null || echo "error")
echo -e "  /api/terminals → $TERMS"

DASH=$(curl -sf https://edge.etheros.ai/api/dashboard 2>/dev/null | python3 -c "import sys,json; d=json.load(sys.stdin); print(f'subs={d.get(\"totalSubscribers\",\"?\")}, terminals={d.get(\"totalTerminals\",\"?\")}') " 2>/dev/null || echo "error")
echo -e "  /api/dashboard → $DASH"

ACQ=$(curl -sf https://edge.etheros.ai/api/acquisition/pages 2>/dev/null | python3 -c "import sys,json; d=json.load(sys.stdin); print(f'[{len(d)} pages]')" 2>/dev/null || echo "error")
echo -e "  /api/acquisition/pages → $ACQ"

echo -e "${GREEN}${BOLD}━━━ Patch complete ━━━${NC}"
