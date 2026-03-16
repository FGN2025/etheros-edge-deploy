#!/usr/bin/env bash
set -euo pipefail

# ─── EtherOS Sprint 4A — Add ISP Tenant ───────────────────────────────────────
# Creates:
#   1. Tenant config JSON          → /opt/etheros-edge/isp-config/<slug>.json
#   2. Tenant data directory       → /opt/etheros-edge/backends/isp-portal/data/<slug>/
#   3. ISP-specific settings seed  → data/<slug>/isp-settings.json
#   4. Nginx vhost (subdomain)     → /opt/etheros-edge/nginx/conf.d/<slug>.conf
#   5. Isolated Docker container   → etheros-isp-<slug>  (port auto-assigned 3020+)
#
# Usage:
#   ./add-isp-tenant.sh --slug valley-fiber --name "Valley Fiber" \
#       --domain edge.valleyfiber.com [--accent "#00C2CB"] [--port 3020]

# ─── Colors ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m'

# ─── Paths ────────────────────────────────────────────────────────────────────
EDGE_DIR="/opt/etheros-edge"
ISP_CONFIG_DIR="${EDGE_DIR}/isp-config"
NGINX_CONF_DIR="${EDGE_DIR}/nginx/conf.d"
BACKEND_DIR="${EDGE_DIR}/backends/isp-portal"
DATA_ROOT="${BACKEND_DIR}/data"
TEMPLATE_DIR="$(cd "$(dirname "$0")" && pwd)/nginx"

# ─── Usage ────────────────────────────────────────────────────────────────────
usage() {
    echo -e "${BOLD}Usage:${NC} $0 --slug <slug> --name <name> --domain <domain> [--accent <color>] [--port <port>]"
    echo ""
    echo "  --slug     Tenant slug (lowercase, hyphens only)    e.g. valley-fiber"
    echo "  --name     Display name                             e.g. \"Valley Fiber\""
    echo "  --domain   Tenant portal domain                     e.g. edge.valleyfiber.com"
    echo "  --accent   Accent hex color (optional)              default: #00C2CB"
    echo "  --port     Host port for this ISP's backend (optional, auto-detected if omitted)"
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
PORT=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --slug)   SLUG="$2";   shift 2 ;;
        --name)   NAME="$2";   shift 2 ;;
        --domain) DOMAIN="$2"; shift 2 ;;
        --accent) ACCENT="$2"; shift 2 ;;
        --port)   PORT="$2";   shift 2 ;;
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

CONTAINER_NAME="etheros-isp-${SLUG}"

# ─── Auto-assign port if not provided ─────────────────────────────────────────
# Scan used ports 3020-3099 and pick the first free one
if [[ -z "$PORT" ]]; then
    PORT=3020
    while docker ps --format '{{.Ports}}' 2>/dev/null | grep -q "127.0.0.1:${PORT}->"; do
        PORT=$((PORT + 1))
        if [[ $PORT -gt 3099 ]]; then
            echo -e "${RED}Error:${NC} All ISP backend ports (3020-3099) are in use."
            exit 1
        fi
    done
fi

echo -e "${CYAN}${BOLD}━━━ EtherOS ISP Tenant Setup (Sprint 4A) ━━━${NC}"
echo -e "${CYAN}Slug:${NC}      ${SLUG}"
echo -e "${CYAN}Name:${NC}      ${NAME}"
echo -e "${CYAN}Domain:${NC}    ${DOMAIN}"
echo -e "${CYAN}Accent:${NC}    ${ACCENT}"
echo -e "${CYAN}Port:${NC}      ${PORT}"
echo -e "${CYAN}Container:${NC} ${CONTAINER_NAME}"
echo ""

# ─── 1. Create directories ───────────────────────────────────────────────────
mkdir -p "$ISP_CONFIG_DIR"
mkdir -p "$NGINX_CONF_DIR"
mkdir -p "${DATA_ROOT}/${SLUG}"

# ─── 2. Write tenant config JSON ─────────────────────────────────────────────
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
  "backend_port": ${PORT},
  "plan_personal_price": 49,
  "plan_professional_price": 99,
  "max_terminals": 500
}
EOF

echo -e "  ${GREEN}✓${NC} Config written"

# ─── 3. Seed isp-settings.json for this tenant ───────────────────────────────
SETTINGS_FILE="${DATA_ROOT}/${SLUG}/isp-settings.json"
if [[ ! -f "$SETTINGS_FILE" ]]; then
    echo -e "${YELLOW}▸${NC} Seeding ISP settings → ${SETTINGS_FILE}"
    cat > "$SETTINGS_FILE" <<EOF
{
  "ispName": "${NAME}",
  "domain": "${DOMAIN}",
  "accentColor": "${ACCENT}",
  "logoUrl": "",
  "supportEmail": "support@${DOMAIN#edge.}",
  "stripeKey": "",
  "stripeWebhookSecret": ""
}
EOF
    echo -e "  ${GREEN}✓${NC} Settings seeded"
else
    echo -e "  ${CYAN}↩${NC} Settings already exist — skipping seed"
fi

# ─── 4. Generate nginx vhost ──────────────────────────────────────────────────
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
    -e "s|__PORT__|${PORT}|g" \
    "$TEMPLATE" > "$VHOST_FILE"

echo -e "  ${GREEN}✓${NC} Vhost generated"

# ─── 5. Spin up isolated backend container ───────────────────────────────────
# Each ISP gets its own container instance of the same backend image,
# pointing at its own data sub-directory under the shared bind mount.
#
# Volume strategy: share the parent bind mount (/opt/etheros-edge/backends/isp-portal)
# so all ISP containers can reach server.js from the same image layer, but each
# container's DATA_DIR resolves to /app/data/<slug> — fully isolated JSON stores.

echo -e "${YELLOW}▸${NC} Checking for existing container '${CONTAINER_NAME}'..."

if docker ps -a --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
    echo -e "  ${YELLOW}!${NC}  Container already exists — removing it to re-provision"
    docker rm -f "$CONTAINER_NAME" >/dev/null
fi

echo -e "${YELLOW}▸${NC} Starting container '${CONTAINER_NAME}' on 127.0.0.1:${PORT}..."

docker run -d \
    --name "$CONTAINER_NAME" \
    --network etheros-edge_edge-internal \
    --restart unless-stopped \
    -p "127.0.0.1:${PORT}:3010" \
    -v "${BACKEND_DIR}:/app:rw" \
    -e "TENANT_SLUG=${SLUG}" \
    -e "TENANT_DOMAIN=${DOMAIN}" \
    -e "NODE_ENV=production" \
    --label "etheros.tenant=${SLUG}" \
    --label "etheros.domain=${DOMAIN}" \
    etheros-edge_etheros-isp-portal-backend

echo -e "  ${GREEN}✓${NC} Container started"

# ─── 6. Reload nginx ──────────────────────────────────────────────────────────
echo -e "${YELLOW}▸${NC} Reloading nginx..."
docker exec etheros-nginx nginx -s reload
echo -e "  ${GREEN}✓${NC} Nginx reloaded"

# ─── 7. Verify container health ──────────────────────────────────────────────
echo -e "${YELLOW}▸${NC} Waiting for container to become healthy..."
RETRIES=12
for i in $(seq 1 $RETRIES); do
    STATUS=$(curl -s -o /dev/null -w "%{http_code}" \
        "http://127.0.0.1:${PORT}/api/tenant" 2>/dev/null || true)
    if [[ "$STATUS" == "200" ]]; then
        echo -e "  ${GREEN}✓${NC} Health check passed (HTTP 200)"
        break
    fi
    if [[ $i -eq $RETRIES ]]; then
        echo -e "  ${YELLOW}!${NC}  Health check timed out — container may still be starting"
    else
        sleep 2
    fi
done

# ─── Done ─────────────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}${BOLD}━━━ ISP Tenant Provisioned ━━━${NC}"
echo -e "${GREEN}Tenant URL:${NC}  https://${DOMAIN}"
echo -e "${GREEN}API:${NC}         http://127.0.0.1:${PORT}/api/tenant"
echo -e "${GREEN}Data dir:${NC}    ${DATA_ROOT}/${SLUG}/"
echo -e "${GREEN}Config:${NC}      ${CONFIG_FILE}"
echo -e "${GREEN}Container:${NC}   ${CONTAINER_NAME}"
echo ""
echo -e "${CYAN}Next steps:${NC}"
echo "  1. Ensure DNS for ${DOMAIN} points to $(curl -s ifconfig.me 2>/dev/null || echo '72.62.160.72')"
echo "  2. Run: certbot certonly --nginx -d ${DOMAIN}"
echo "  3. Log into the ISP Portal at https://${DOMAIN}/isp-portal/"
echo "     and complete the Settings → General setup (Stripe key, etc.)"
