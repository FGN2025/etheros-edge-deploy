#!/usr/bin/env bash
# deploy-static-apps.sh
# Downloads the built ISP Portal + Marketplace static files from GitHub,
# deploys them to /opt/etheros-edge/static/, and patches nginx to serve them.
set -e

EDGE_DIR="/opt/etheros-edge"
STATIC_DIR="$EDGE_DIR/static"
GITHUB_RAW="https://raw.githubusercontent.com/FGN2025/etheros-edge-deploy/main"
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'

echo ""
echo -e "${YELLOW}══════════════════════════════════════════════════${NC}"
echo -e "${YELLOW}  EtherOS — Deploy Static Apps to VPS             ${NC}"
echo -e "${YELLOW}══════════════════════════════════════════════════${NC}"
echo ""

# ── Step 1: Create static dirs ────────────────────────────────────────────────
echo -e "${YELLOW}▸${NC} Creating static directories..."
mkdir -p "$STATIC_DIR/isp-portal"
mkdir -p "$STATIC_DIR/marketplace"
echo -e "  ${GREEN}✓${NC} Directories ready"

# ── Step 2: Download and extract tarballs ─────────────────────────────────────
echo -e "${YELLOW}▸${NC} Downloading ISP Portal static build..."
curl -fsSL "$GITHUB_RAW/isp-portal-dist.tar.gz" -o /tmp/isp-portal-dist.tar.gz
tar xzf /tmp/isp-portal-dist.tar.gz -C "$STATIC_DIR/isp-portal"
echo -e "  ${GREEN}✓${NC} ISP Portal extracted ($(ls $STATIC_DIR/isp-portal | wc -l) files)"

echo -e "${YELLOW}▸${NC} Downloading Marketplace static build..."
curl -fsSL "$GITHUB_RAW/marketplace-dist.tar.gz" -o /tmp/marketplace-dist.tar.gz
tar xzf /tmp/marketplace-dist.tar.gz -C "$STATIC_DIR/marketplace"
echo -e "  ${GREEN}✓${NC} Marketplace extracted ($(ls $STATIC_DIR/marketplace | wc -l) files)"

# ── Step 3: Patch nginx to serve static files ─────────────────────────────────
echo -e "${YELLOW}▸${NC} Patching nginx config..."
NGINX_CONF="$EDGE_DIR/nginx/conf.d/etheros-edge.conf"

python3 << PYEOF
content = open('$NGINX_CONF').read()

static_locations = """
    # ISP Portal static app
    location /isp-portal/ {
        alias /opt/etheros-edge/static/isp-portal/;
        try_files \$uri \$uri/ /isp-portal/index.html;
        add_header Cache-Control "no-cache";
    }

    # Marketplace static app
    location /marketplace/ {
        alias /opt/etheros-edge/static/marketplace/;
        try_files \$uri \$uri/ /marketplace/index.html;
        add_header Cache-Control "no-cache";
    }
"""

# Only patch if not already there
if '/isp-portal/' not in content:
    # Insert before the ISP Portal API block
    insert_before = '    # ISP Portal backend API'
    if insert_before in content:
        content = content.replace(insert_before, static_locations + '\n' + insert_before)
    else:
        # Fallback: insert before the first backend health check
        insert_before = '    location /isp-portal/health'
        content = content.replace(insert_before, static_locations + '\n' + insert_before)
    open('$NGINX_CONF', 'w').write(content)
    print('nginx patched')
else:
    print('nginx already has static locations — skipping')
PYEOF
echo -e "  ${GREEN}✓${NC} nginx config updated"

# ── Step 4: Reload nginx ──────────────────────────────────────────────────────
echo -e "${YELLOW}▸${NC} Reloading nginx..."
docker exec etheros-nginx nginx -t && docker exec etheros-nginx nginx -s reload
echo -e "  ${GREEN}✓${NC} nginx reloaded"

# ── Step 5: Verify ────────────────────────────────────────────────────────────
echo ""
echo -e "${YELLOW}▸${NC} Verification..."
sleep 2

ISP=$(curl -sf -o /dev/null -w "%{http_code}" https://edge.etheros.ai/isp-portal/ || echo "FAIL")
MKT=$(curl -sf -o /dev/null -w "%{http_code}" https://edge.etheros.ai/marketplace/ || echo "FAIL")
echo -e "  ISP Portal:   https://edge.etheros.ai/isp-portal/  → HTTP $ISP"
echo -e "  Marketplace:  https://edge.etheros.ai/marketplace/ → HTTP $MKT"

echo ""
echo -e "${GREEN}══════════════════════════════════════════════════${NC}"
echo -e "${GREEN}  Static apps deployed!                           ${NC}"
echo -e "${GREEN}══════════════════════════════════════════════════${NC}"
echo ""
echo "  → ISP Portal:  https://edge.etheros.ai/isp-portal/"
echo "  → Marketplace: https://edge.etheros.ai/marketplace/"
echo ""
