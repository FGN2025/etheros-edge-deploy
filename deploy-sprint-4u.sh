#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════════
# EtherOS — Sprint 4U Deploy: Pre-Live Hardening
#
# Changes deployed:
#   - Stripe credentials externalized to process.env (STRIPE_SECRET_KEY,
#     STRIPE_WEBHOOK_SECRET) via docker-compose.override.yml
#   - BillingScreen "Subscribe Now" empty-email bug fixed
#   - GET /api/subscribers/checkout-result endpoint for post-Stripe PIN display
#   - CheckoutSuccessScreen in terminal UI — shows PIN after Stripe redirect
#   - Ollama service added via docker-compose.override.yml (llama3.2:3b pulled)
#   - Frontend bundle updated (index-kZ53NXg-.js)
#
# Run on VPS — pass Stripe keys as env vars:
#   STRIPE_SECRET_KEY=sk_test_... STRIPE_WEBHOOK_SECRET=whsec_... \
#     bash <(curl -fsSL https://raw.githubusercontent.com/FGN2025/etheros-edge-deploy/main/deploy-sprint-4u.sh)
#
# Or run interactively (script will prompt):
#   curl -fsSL https://raw.githubusercontent.com/FGN2025/etheros-edge-deploy/main/deploy-sprint-4u.sh | bash
# ═══════════════════════════════════════════════════════════════════════════════
set -euo pipefail

GREEN='\033[0;32m'; CYAN='\033[0;36m'; YELLOW='\033[1;33m'; BOLD='\033[1m'; RED='\033[0;31m'; NC='\033[0m'
REPO="https://raw.githubusercontent.com/FGN2025/etheros-edge-deploy/main"
BACKEND="/opt/etheros-edge/backends/isp-portal"
ROUTES="$BACKEND/routes"
STATIC="/opt/etheros-edge/static/isp-portal"
EDGE_DIR="/opt/etheros-edge"

echo -e "${CYAN}${BOLD}━━━ EtherOS Sprint 4U — Pre-Live Hardening ━━━${NC}"
echo ""

# ── Pull updated backend files ─────────────────────────────────────────────────
echo -e "${YELLOW}▸${NC} Pulling backend files..."
curl -fsSL "$REPO/backends/isp-portal/server.js"         -o "$BACKEND/server.js"
curl -fsSL "$REPO/backends/isp-portal/routes/billing.js" -o "$ROUTES/billing.js"
echo -e "  ${GREEN}✓${NC} server.js + billing.js updated"

# ── Pull updated frontend bundle ───────────────────────────────────────────────
echo -e "${YELLOW}▸${NC} Updating frontend static bundle..."
mkdir -p "$STATIC/assets"
curl -fsSL "$REPO/static/isp-portal/index.html"                  -o "$STATIC/index.html"
curl -fsSL "$REPO/static/isp-portal/assets/index-kZ53NXg-.js"   -o "$STATIC/assets/index-kZ53NXg-.js"
curl -fsSL "$REPO/static/isp-portal/assets/index-D37hKAr6.css"  -o "$STATIC/assets/index-D37hKAr6.css"
# Remove old JS bundle
rm -f "$STATIC/assets/index-BU7il5dZ.js"
echo -e "  ${GREEN}✓${NC} Static bundle updated (index-kZ53NXg-.js)"

# ── Collect Stripe keys ────────────────────────────────────────────────────────
echo ""
echo -e "${YELLOW}▸${NC} Stripe credential setup..."

if [ -z "${STRIPE_SECRET_KEY:-}" ]; then
  printf "  Enter STRIPE_SECRET_KEY (sk_test_...): "
  read -r STRIPE_SECRET_KEY
fi
if [ -z "${STRIPE_WEBHOOK_SECRET:-}" ]; then
  printf "  Enter STRIPE_WEBHOOK_SECRET (whsec_...): "
  read -r STRIPE_WEBHOOK_SECRET
fi

# ── Write docker-compose.override.yml ─────────────────────────────────────────
# This merges on top of the existing docker-compose.yml without modifying it.
# It adds Stripe env vars to isp-portal-backend and adds the Ollama service.
echo -e "${YELLOW}▸${NC} Writing docker-compose.override.yml..."

OVERRIDE_FILE="$EDGE_DIR/docker-compose.override.yml"

cat > "$OVERRIDE_FILE" << OVERRIDE
version: '3.8'

services:
  etheros-isp-portal-backend:
    environment:
      - STRIPE_SECRET_KEY=${STRIPE_SECRET_KEY}
      - STRIPE_WEBHOOK_SECRET=${STRIPE_WEBHOOK_SECRET}

  ollama:
    image: ollama/ollama:latest
    container_name: etheros-ollama
    restart: unless-stopped
    volumes:
      - ./data/ollama:/root/.ollama
    networks:
      - etheros-net
    ports:
      - "127.0.0.1:11434:11434"
    environment:
      - OLLAMA_KEEP_ALIVE=24h
      - OLLAMA_NUM_PARALLEL=2
OVERRIDE

echo -e "  ${GREEN}✓${NC} docker-compose.override.yml written"

# ── Ensure ollama data dir exists ──────────────────────────────────────────────
mkdir -p "$EDGE_DIR/data/ollama"

# ── Bring up / recreate isp-portal-backend with new env vars ──────────────────
echo ""
echo -e "${YELLOW}▸${NC} Recreating isp-portal-backend with Stripe env vars..."
cd "$EDGE_DIR"
docker compose up -d --no-deps --force-recreate etheros-isp-portal-backend
sleep 6
echo -e "  ${GREEN}✓${NC} isp-portal-backend recreated"

# ── Start Ollama ───────────────────────────────────────────────────────────────
echo ""
echo -e "${YELLOW}▸${NC} Starting Ollama service..."
docker compose up -d ollama
sleep 4
OLLAMA_STATUS=$(docker ps --filter "name=etheros-ollama" --format "{{.Status}}" 2>/dev/null || echo "not found")
echo -e "  Container: $OLLAMA_STATUS"

# ── Pull llama3.2:3b model ─────────────────────────────────────────────────────
echo ""
echo -e "${YELLOW}▸${NC} Checking for llama3.2:3b model..."
if docker exec etheros-ollama ollama list 2>/dev/null | grep -q "llama3.2:3b"; then
  echo -e "  ${GREEN}✓${NC} llama3.2:3b already present"
else
  echo -e "  ${CYAN}ℹ${NC}  Pulling llama3.2:3b in background (~2 GB — takes a few minutes)..."
  docker exec -d etheros-ollama ollama pull llama3.2:3b
  echo -e "  ${CYAN}ℹ${NC}  Monitor: docker logs -f etheros-ollama"
  echo -e "  ${CYAN}ℹ${NC}  Chat will return 500 until pull completes"
fi

# ── Health check ──────────────────────────────────────────────────────────────
echo ""
echo -e "${YELLOW}▸${NC} Health check..."
sleep 2
HEALTH=$(curl -sf https://edge.etheros.ai/health 2>/dev/null || echo '{}')
echo -e "  /health → $HEALTH"

# ── Public endpoint verification ──────────────────────────────────────────────
echo ""
echo -e "${YELLOW}▸${NC} Public endpoint verification (expect 200)..."
for ep in /health /api/tenant /api/terminal/config /api/billing/plans; do
  STATUS=$(curl -s -o /dev/null -w "%{http_code}" "https://edge.etheros.ai${ep}" 2>/dev/null)
  if [ "$STATUS" = "200" ]; then
    echo -e "  ${GREEN}✓${NC} 200  $ep"
  else
    echo -e "  ${RED}✗${NC} $STATUS  $ep  ← UNEXPECTED"
  fi
done

# checkout-result with unknown session → 200 with ok:false
CHECKOUT_STATUS=$(curl -s -o /dev/null -w "%{http_code}" \
  "https://edge.etheros.ai/isp-portal/api/subscribers/checkout-result?session_id=test_sprint4u" 2>/dev/null)
if [ "$CHECKOUT_STATUS" = "200" ]; then
  echo -e "  ${GREEN}✓${NC} 200  /isp-portal/api/subscribers/checkout-result (new endpoint)"
else
  echo -e "  ${RED}✗${NC} $CHECKOUT_STATUS  /isp-portal/api/subscribers/checkout-result"
fi

# ── Auth gate spot check ───────────────────────────────────────────────────────
echo ""
echo -e "${YELLOW}▸${NC} Auth gate spot check (expect 401)..."
for ep in /api/settings /api/subscribers /api/terminals; do
  STATUS=$(curl -s -o /dev/null -w "%{http_code}" https://edge.etheros.ai${ep} 2>/dev/null)
  if [ "$STATUS" = "401" ]; then
    echo -e "  ${GREEN}✓${NC} 401  $ep"
  else
    echo -e "  ${RED}✗${NC} $STATUS  $ep  ← UNEXPECTED"
  fi
done

# ── Stripe env verification ────────────────────────────────────────────────────
echo ""
echo -e "${YELLOW}▸${NC} Verifying Stripe env vars in container..."
STRIPE_CHECK=$(docker exec etheros-isp-portal-backend sh -c 'echo $STRIPE_SECRET_KEY' 2>/dev/null | cut -c1-20 || echo "(error)")
if [[ "$STRIPE_CHECK" == sk_* ]]; then
  echo -e "  ${GREEN}✓${NC} STRIPE_SECRET_KEY present (${STRIPE_CHECK}...)"
else
  echo -e "  ${RED}✗${NC} STRIPE_SECRET_KEY not found — override may not have applied"
fi
WEBHOOK_CHECK=$(docker exec etheros-isp-portal-backend sh -c 'echo $STRIPE_WEBHOOK_SECRET' 2>/dev/null | cut -c1-10 || echo "(error)")
if [[ "$WEBHOOK_CHECK" == whsec_* ]]; then
  echo -e "  ${GREEN}✓${NC} STRIPE_WEBHOOK_SECRET present"
else
  echo -e "  ${RED}✗${NC} STRIPE_WEBHOOK_SECRET not found"
fi

# ── Ollama status ─────────────────────────────────────────────────────────────
echo ""
echo -e "${YELLOW}▸${NC} Ollama status..."
OLLAMA_PING=$(curl -sf http://127.0.0.1:11434/api/tags 2>/dev/null | \
  python3 -c "import sys,json; d=json.load(sys.stdin); names=[m['name'] for m in d.get('models',[])]; print('models: '+', '.join(names) if names else 'running — no models yet (pull in progress)')" \
  2>/dev/null || echo "unreachable (container may still be starting)")
echo -e "  $OLLAMA_PING"

echo ""
echo -e "${GREEN}${BOLD}━━━ Sprint 4U deploy complete ━━━${NC}"
echo -e "  Commit: 7c326ac"
echo -e ""
echo -e "  ${CYAN}What changed:${NC}"
echo -e "  • Stripe creds injected via docker-compose.override.yml (TEST mode)"
echo -e "  • Checkout success screen: users see their PIN after Stripe payment"
echo -e "  • Ollama container started, llama3.2:3b pull initiated"
echo -e ""
echo -e "  ${YELLOW}Remaining pre-live steps:${NC}"
echo -e "  • Register Stripe webhook in dashboard.stripe.com/test/webhooks"
echo -e "    URL: https://edge.etheros.ai/isp-portal/api/billing/webhook"
echo -e "    Events: checkout.session.completed, customer.subscription.updated,"
echo -e "            customer.subscription.deleted, invoice.payment_succeeded,"
echo -e "            invoice.payment_failed"
echo -e "  • Wait for Ollama model pull: docker logs -f etheros-ollama"
echo -e "  • Rotate GitHub PAT: https://github.com/settings/tokens"
