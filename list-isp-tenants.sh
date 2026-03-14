#!/usr/bin/env bash
set -euo pipefail

# ─── EtherOS Sprint 3B — List ISP Tenants ─────────────────────────────────────

# Colors
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

ISP_CONFIG_DIR="/opt/etheros-edge/isp-config"

# ─── Check config dir ────────────────────────────────────────────────────────
if [[ ! -d "$ISP_CONFIG_DIR" ]]; then
    echo -e "${CYAN}No ISP tenants configured yet.${NC}"
    echo "  Config directory not found: ${ISP_CONFIG_DIR}"
    echo "  Run add-isp-tenant.sh to create your first tenant."
    exit 0
fi

# ─── Find tenant configs ─────────────────────────────────────────────────────
shopt -s nullglob
CONFIG_FILES=("${ISP_CONFIG_DIR}"/*.json)
shopt -u nullglob

if [[ ${#CONFIG_FILES[@]} -eq 0 ]]; then
    echo -e "${CYAN}No ISP tenants configured yet.${NC}"
    exit 0
fi

# ─── Print header ─────────────────────────────────────────────────────────────
echo -e "${CYAN}${BOLD}━━━ EtherOS ISP Tenants ━━━${NC}"
echo ""
printf "${BOLD}%-20s %-25s %-35s %s${NC}\n" "SLUG" "NAME" "DOMAIN" "MAX TERMINALS"
printf "${DIM}%-20s %-25s %-35s %s${NC}\n" "────────────────────" "─────────────────────────" "───────────────────────────────────" "─────────────"

# ─── List tenants ─────────────────────────────────────────────────────────────
COUNT=0
for config in "${CONFIG_FILES[@]}"; do
    SLUG=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['slug'])" "$config" 2>/dev/null || echo "?")
    NAME=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['name'])" "$config" 2>/dev/null || echo "?")
    DOMAIN=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['domain'])" "$config" 2>/dev/null || echo "?")
    MAX_T=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1])).get('max_terminals','—'))" "$config" 2>/dev/null || echo "—")

    printf "%-20s %-25s %-35s %s\n" "$SLUG" "$NAME" "$DOMAIN" "$MAX_T"
    COUNT=$((COUNT + 1))
done

echo ""
echo -e "${DIM}${COUNT} tenant(s) configured${NC}"
