#!/usr/bin/env bash
# Fix: backends were calling edge.etheros.ai (public URL) from inside Docker
# That loopbacks to themselves — can't reach the host's public IP from containers
# Fix: use internal Docker hostname etheros-open-webui:8080 directly

set -euo pipefail
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BOLD='\033[1m'; NC='\033[0m'

echo -e "${YELLOW}▸${NC} Patching ISP Portal backend — internal Docker networking..."
sed -i "s|const EDGE_API = 'https://edge.etheros.ai/api';|const EDGE_API = 'http://etheros-open-webui:8080/api';|g" \
  /opt/etheros-edge/backends/isp-portal/server.js
echo -e "  ${GREEN}✓${NC} ISP Portal patched"

echo -e "${YELLOW}▸${NC} Patching Marketplace backend — internal Docker networking..."
sed -i "s|const EDGE_API = 'https://edge.etheros.ai/api';|const EDGE_API = 'http://etheros-open-webui:8080/api';|g" \
  /opt/etheros-edge/backends/marketplace/server.js
echo -e "  ${GREEN}✓${NC} Marketplace patched"

echo -e "${YELLOW}▸${NC} Restarting backend containers..."
cd /opt/etheros-edge
docker compose restart isp-portal-backend marketplace-backend
sleep 4
echo -e "  ${GREEN}✓${NC} Containers restarted"

echo -e "${YELLOW}▸${NC} Testing edge status..."
sleep 2
curl -s http://localhost:3010/api/edge-status | python3 -m json.tool | grep -E "edgeOnline|models|ollamaOnline"

echo ""
echo -e "${YELLOW}▸${NC} Testing live chat (ValleyBot / phi3:mini)..."
curl -s -X POST http://localhost:3011/api/chat \
  -H "Content-Type: application/json" \
  -d '{"agentId":"agent-4","message":"Hello! What can you help me with?"}' \
  | python3 -m json.tool | grep -E "reply|model|agentName"

echo ""
echo -e "${GREEN}${BOLD}━━━ Backend fix complete ━━━${NC}"
