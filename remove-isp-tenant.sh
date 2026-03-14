#!/usr/bin/env bash
set -euo pipefail

# ─── EtherOS Sprint 3B — Remove ISP Tenant ────────────────────────────────────

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m'

EDGE_DIR="/opt/etheros-edge"
ISP_CONFIG_DIR="${EDGE_DIR}/isp-config"
NGINX_CONF_DIR="${EDGE_DIR}/nginx/conf.d"

# ─── Usage ────────────────────────────────────────────────────────────────────
usage() {
    echo -e "${BOLD}Usage:${NC} $0 --slug <slug>"
    echo ""
    echo "  --slug   Tenant slug to remove    e.g. valley-fiber"
    echo ""
    echo -e "${BOLD}Example:${NC}"
    echo "  $0 --slug valley-fiber"
    exit 1
}

# ─── Parse args ───────────────────────────────────────────────────────────────
SLUG=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --slug) SLUG="$2"; shift 2 ;;
        *)      echo -e "${RED}Unknown argument: $1${NC}"; usage ;;
    esac
done

if [[ -z "$SLUG" ]]; then
    echo -e "${RED}Error:${NC} --slug is required."
    echo ""
    usage
fi

# ─── Validate tenant exists ──────────────────────────────────────────────────
CONFIG_FILE="${ISP_CONFIG_DIR}/${SLUG}.json"
VHOST_FILE="${NGINX_CONF_DIR}/${SLUG}.conf"

if [[ ! -f "$CONFIG_FILE" ]]; then
    echo -e "${RED}Error:${NC} Tenant '${SLUG}' not found at ${CONFIG_FILE}"
    exit 1
fi

# ─── Confirm ──────────────────────────────────────────────────────────────────
TENANT_NAME=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['name'])" "$CONFIG_FILE" 2>/dev/null || echo "$SLUG")
TENANT_DOMAIN=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['domain'])" "$CONFIG_FILE" 2>/dev/null || echo "unknown")

echo -e "${CYAN}${BOLD}━━━ EtherOS Remove ISP Tenant ━━━${NC}"
echo -e "${YELLOW}Tenant:${NC} ${TENANT_NAME} (${SLUG})"
echo -e "${YELLOW}Domain:${NC} ${TENANT_DOMAIN}"
echo ""

# ─── Remove config ────────────────────────────────────────────────────────────
echo -e "${YELLOW}▸${NC} Removing tenant config..."
rm -f "$CONFIG_FILE"
echo -e "  ${GREEN}✓${NC} Removed ${CONFIG_FILE}"

# ─── Remove nginx vhost ──────────────────────────────────────────────────────
if [[ -f "$VHOST_FILE" ]]; then
    echo -e "${YELLOW}▸${NC} Removing nginx vhost..."
    rm -f "$VHOST_FILE"
    echo -e "  ${GREEN}✓${NC} Removed ${VHOST_FILE}"
else
    echo -e "  ${YELLOW}⚠${NC} No nginx vhost found at ${VHOST_FILE} (skipped)"
fi

# ─── Reload nginx ─────────────────────────────────────────────────────────────
echo -e "${YELLOW}▸${NC} Reloading nginx..."
docker exec etheros-nginx nginx -s reload
echo -e "  ${GREEN}✓${NC} Nginx reloaded"

# ─── Done ─────────────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}${BOLD}━━━ Tenant '${SLUG}' Removed ━━━${NC}"
echo -e "  The domain https://${TENANT_DOMAIN} will no longer serve traffic."
