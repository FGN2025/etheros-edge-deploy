#!/usr/bin/env bash
set -euo pipefail

# ─── EtherOS Sprint 3B — Add ISP Tenant ───────────────────────────────────────
# Creates an ISP tenant config and nginx vhost on the edge node.

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
TEMPLATE_DIR="$(cd "$(dirname "$0")" && pwd)/nginx"

# ─── Usage ────────────────────────────────────────────────────────────────────
usage() {
    echo -e "${BOLD}Usage:${NC} $0 --slug <slug> --name <name> --domain <domain> [--accent <color>]"
    echo ""
    echo "  --slug     Tenant slug (lowercase, hyphens only)    e.g. valley-fiber"
    echo "  --name     Display name                             e.g. \"Valley Fiber\""
    echo "  --domain   Tenant domain                            e.g. edge.valleyfiber.com"
    echo "  --accent   Accent hex color (optional)              default: #00C2CB"
    echo ""
    echo -e "${BOLD}Example:${NC}"
    echo "  $0 --slug valley-fiber --name \"Valley Fiber\" --domain edge.valleyfiber.com"
    exit 1
}

# ─── Parse args ───────────────────────────────────────────────────────────────
SLUG=""
NAME=""
DOMAIN=""
ACCENT="#00C2CB"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --slug)   SLUG="$2";   shift 2 ;;
        --name)   NAME="$2";   shift 2 ;;
        --domain) DOMAIN="$2"; shift 2 ;;
        --accent) ACCENT="$2"; shift 2 ;;
        *)        echo -e "${RED}Unknown argument: $1${NC}"; usage ;;
    esac
done

# ─── Validate ─────────────────────────────────────────────────────────────────
if [[ -z "$SLUG" || -z "$NAME" || -z "$DOMAIN" ]]; then
    echo -e "${RED}Error:${NC} --slug, --name, and --domain are required."
    echo ""
    usage
fi

if [[ ! "$SLUG" =~ ^[a-z0-9-]+$ ]]; then
    echo -e "${RED}Error:${NC} Slug must contain only lowercase letters, numbers, and hyphens."
    exit 1
fi

echo -e "${CYAN}${BOLD}━━━ EtherOS ISP Tenant Setup ━━━${NC}"
echo -e "${CYAN}Slug:${NC}   ${SLUG}"
echo -e "${CYAN}Name:${NC}   ${NAME}"
echo -e "${CYAN}Domain:${NC} ${DOMAIN}"
echo -e "${CYAN}Accent:${NC} ${ACCENT}"
echo ""

# ─── Create directories ──────────────────────────────────────────────────────
mkdir -p "$ISP_CONFIG_DIR"
mkdir -p "$NGINX_CONF_DIR"

# ─── Write tenant config JSON ────────────────────────────────────────────────
CONFIG_FILE="${ISP_CONFIG_DIR}/${SLUG}.json"
echo -e "${YELLOW}▸${NC} Writing tenant config → ${CONFIG_FILE}"

cat > "$CONFIG_FILE" <<EOF
{
  "slug": "${SLUG}",
  "name": "${NAME}",
  "domain": "${DOMAIN}",
  "logo_url": "",
  "accent_color": "${ACCENT}",
  "primary_color": "#0D1B2A",
  "support_email": "support@${DOMAIN#edge.}",
  "plan_personal_price": 49,
  "plan_professional_price": 99,
  "max_terminals": 500
}
EOF

echo -e "  ${GREEN}✓${NC} Config written"

# ─── Generate nginx vhost from template ───────────────────────────────────────
TEMPLATE="${TEMPLATE_DIR}/tenant-vhost.conf.template"
VHOST_FILE="${NGINX_CONF_DIR}/${SLUG}.conf"

if [[ ! -f "$TEMPLATE" ]]; then
    echo -e "${RED}Error:${NC} Nginx template not found at ${TEMPLATE}"
    exit 1
fi

echo -e "${YELLOW}▸${NC} Generating nginx vhost → ${VHOST_FILE}"

sed \
    -e "s|__DOMAIN__|${DOMAIN}|g" \
    -e "s|__SLUG__|${SLUG}|g" \
    -e "s|__ISP_NAME__|${NAME}|g" \
    -e "s|__ACCENT_COLOR__|${ACCENT}|g" \
    "$TEMPLATE" > "$VHOST_FILE"

echo -e "  ${GREEN}✓${NC} Vhost generated"

# ─── Reload nginx ─────────────────────────────────────────────────────────────
echo -e "${YELLOW}▸${NC} Reloading nginx..."
docker exec etheros-nginx nginx -s reload
echo -e "  ${GREEN}✓${NC} Nginx reloaded"

# ─── Done ─────────────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}${BOLD}━━━ ISP Tenant Added Successfully ━━━${NC}"
echo -e "${GREEN}Tenant URL:${NC} https://${DOMAIN}"
echo -e "${GREEN}Config:${NC}     ${CONFIG_FILE}"
echo -e "${GREEN}Vhost:${NC}      ${VHOST_FILE}"
echo ""
echo -e "${CYAN}Next steps:${NC}"
echo "  1. Ensure DNS for ${DOMAIN} points to 72.62.160.72"
echo "  2. Run: certbot certonly --standalone -d ${DOMAIN}"
echo "  3. Run: python3 docker-compose-patch.py --slug ${SLUG}"
