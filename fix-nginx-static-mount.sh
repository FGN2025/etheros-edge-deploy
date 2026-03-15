#!/usr/bin/env bash
# fix-nginx-static-mount.sh
# Adds /opt/etheros-edge/static volume mount to the nginx container
# then recreates it so nginx can serve the static SPA files
set -e
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
EDGE_DIR="/opt/etheros-edge"

echo ""
echo -e "${YELLOW}══════════════════════════════════════════════════${NC}"
echo -e "${YELLOW}  EtherOS — Add Static Mount to nginx Container   ${NC}"
echo -e "${YELLOW}══════════════════════════════════════════════════${NC}"
echo ""

# ── Patch docker-compose.yml to add static mount to nginx service ─────────────
echo -e "${YELLOW}▸${NC} Patching docker-compose.yml..."
python3 << 'PYEOF'
import yaml
from pathlib import Path

compose_path = Path('/opt/etheros-edge/docker-compose.yml')
data = yaml.safe_load(compose_path.read_text())

nginx_svc = data['services'].get('nginx', {})
volumes = nginx_svc.get('volumes', [])

static_mount = '/opt/etheros-edge/static:/opt/etheros-edge/static:ro'

if static_mount not in volumes:
    volumes.append(static_mount)
    nginx_svc['volumes'] = volumes
    data['services']['nginx'] = nginx_svc
    compose_path.write_text(yaml.dump(data, default_flow_style=False, sort_keys=False))
    print(f"Added mount: {static_mount}")
else:
    print("Mount already present — skipping")
PYEOF
echo -e "  ${GREEN}✓${NC} docker-compose.yml updated"

# ── Recreate nginx container (picks up new volume mount) ─────────────────────
echo ""
echo -e "${YELLOW}▸${NC} Recreating nginx container (< 5s downtime)..."
cd "$EDGE_DIR"
docker compose up -d --no-deps --force-recreate nginx
sleep 4
echo -e "  ${GREEN}✓${NC} nginx container recreated"

# ── Verify the mount is now present ──────────────────────────────────────────
echo ""
echo -e "${YELLOW}▸${NC} Verifying mounts in new nginx container..."
docker inspect etheros-nginx --format '{{range .Mounts}}  {{.Source}} -> {{.Destination}}{{"\n"}}{{end}}'

# ── Test static file access from inside container ─────────────────────────────
echo ""
echo -e "${YELLOW}▸${NC} Testing file visibility inside nginx container..."
docker exec etheros-nginx ls /opt/etheros-edge/static/marketplace/ 2>/dev/null \
  && echo -e "  ${GREEN}✓${NC} Marketplace files visible inside container" \
  || echo -e "  FAIL: still can't see static files"

docker exec etheros-nginx ls /opt/etheros-edge/static/isp-portal/ 2>/dev/null \
  && echo -e "  ${GREEN}✓${NC} ISP Portal files visible inside container" \
  || echo -e "  FAIL: still can't see static files"

# ── Live HTTP tests ───────────────────────────────────────────────────────────
echo ""
echo -e "${YELLOW}▸${NC} HTTP verification..."
sleep 2
ISP=$(curl -sk -o /dev/null -w "%{http_code}" https://edge.etheros.ai/isp-portal/)
MKT=$(curl -sk -o /dev/null -w "%{http_code}" https://edge.etheros.ai/marketplace/)
echo -e "  https://edge.etheros.ai/isp-portal/  → HTTP $ISP"
echo -e "  https://edge.etheros.ai/marketplace/ → HTTP $MKT"

echo ""
echo -e "${GREEN}══════════════════════════════════════════════════${NC}"
echo -e "${GREEN}  Done!                                           ${NC}"
echo -e "${GREEN}══════════════════════════════════════════════════${NC}"
echo ""
echo "  → ISP Portal:  https://edge.etheros.ai/isp-portal/"
echo "  → Marketplace: https://edge.etheros.ai/marketplace/"
echo ""
