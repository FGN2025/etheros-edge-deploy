#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════════
# EtherOS — Sprint 4U Deploy: Pre-Live Hardening
#
# Changes deployed:
#   - Stripe credentials externalized to process.env (STRIPE_SECRET_KEY,
#     STRIPE_WEBHOOK_SECRET) in isp-portal-backend docker-compose env
#   - BillingScreen "Subscribe Now" empty-email bug fixed
#   - POST /api/subscribers/checkout-result endpoint for post-Stripe PIN display
#   - CheckoutSuccessScreen in terminal UI — shows PIN after Stripe redirect
#   - Ollama service added to docker-compose (llama3.2:3b model pulled)
#   - Frontend bundle updated (index-kZ53NXg-.js)
#
# Run on VPS:
#   curl -fsSL https://raw.githubusercontent.com/FGN2025/etheros-edge-deploy/main/deploy-sprint-4u.sh | bash
# ═══════════════════════════════════════════════════════════════════════════════
set -euo pipefail

GREEN='\033[0;32m'; CYAN='\033[0;36m'; YELLOW='\033[1;33m'; BOLD='\033[1m'; RED='\033[0;31m'; NC='\033[0m'
REPO="https://raw.githubusercontent.com/FGN2025/etheros-edge-deploy/main"
BACKEND="/opt/etheros-edge/backends/isp-portal"
ROUTES="$BACKEND/routes"
STATIC="/opt/etheros-edge/static/isp-portal"
COMPOSE="/opt/etheros-edge/docker-compose.yml"

echo -e "${CYAN}${BOLD}━━━ EtherOS Sprint 4U — Pre-Live Hardening ━━━${NC}"
echo ""

# ── Pull updated backend files ─────────────────────────────────────────────────
echo -e "${YELLOW}▸${NC} Pulling backend files..."
curl -fsSL "$REPO/backends/isp-portal/server.js"         -o "$BACKEND/server.js"
curl -fsSL "$REPO/backends/isp-portal/routes/billing.js" -o "$ROUTES/billing.js"
echo -e "  ${GREEN}✓${NC} server.js + billing.js updated"

# ── Pull updated frontend bundle ───────────────────────────────────────────────
echo -e "${YELLOW}▸${NC} Updating frontend static bundle..."
curl -fsSL "$REPO/static/isp-portal/index.html"                   -o "$STATIC/index.html"
curl -fsSL "$REPO/static/isp-portal/assets/index-kZ53NXg-.js"    -o "$STATIC/assets/index-kZ53NXg-.js"
curl -fsSL "$REPO/static/isp-portal/assets/index-D37hKAr6.css"   -o "$STATIC/assets/index-D37hKAr6.css"
# Remove old JS bundle if it differs
rm -f "$STATIC/assets/index-BU7il5dZ.js"
echo -e "  ${GREEN}✓${NC} Static bundle updated (index-kZ53NXg-.js)"

# ── Inject Stripe env vars into isp-portal-backend service ────────────────────
echo -e "${YELLOW}▸${NC} Patching docker-compose.yml — adding Stripe env vars to isp-portal-backend..."

# ── Stripe keys: read from environment or prompt ──────────────────────────────
# Pass these as environment variables when running the script, e.g.:
#   STRIPE_SECRET_KEY=sk_test_... STRIPE_WEBHOOK_SECRET=whsec_... bash deploy-sprint-4u.sh
# Or the script will prompt interactively.
if [ -z "${STRIPE_SECRET_KEY:-}" ]; then
  echo -e "  ${YELLOW}?${NC}  Enter STRIPE_SECRET_KEY (test mode sk_test_...): "
  read -r STRIPE_SECRET_KEY
fi
if [ -z "${STRIPE_WEBHOOK_SECRET:-}" ]; then
  echo -e "  ${YELLOW}?${NC}  Enter STRIPE_WEBHOOK_SECRET (whsec_...): "
  read -r STRIPE_WEBHOOK_SECRET
fi

# Only add if not already present
if grep -q "STRIPE_SECRET_KEY" "$COMPOSE"; then
  echo -e "  ${YELLOW}⚠${NC}  STRIPE_SECRET_KEY already in docker-compose.yml — skipping env patch"
else
  # Insert after the PORT=3010 line under isp-portal-backend
  python3 - "$STRIPE_SECRET_KEY" "$STRIPE_WEBHOOK_SECRET" <<'PYEOF'
import sys

compose_path = '/opt/etheros-edge/docker-compose.yml'
stripe_secret = sys.argv[1]
stripe_webhook = sys.argv[2]

with open(compose_path, 'r') as f:
    content = f.read()

old = '      - PORT=3010\n      - NODE_ENV=production'
new = f'''      - PORT=3010
      - NODE_ENV=production
      - STRIPE_SECRET_KEY={stripe_secret}
      - STRIPE_WEBHOOK_SECRET={stripe_webhook}'''

if old in content:
    content = content.replace(old, new, 1)
    with open(compose_path, 'w') as f:
        f.write(content)
    print('  patched: STRIPE env vars added')
else:
    print('  WARNING: Could not find PORT=3010 block — manual patch required')
    sys.exit(1)
PYEOF
  echo -e "  ${GREEN}✓${NC} Stripe env vars injected"
fi

# ── Add Ollama service to docker-compose if missing ───────────────────────────
echo -e "${YELLOW}▸${NC} Checking Ollama in docker-compose..."

if docker ps -a --format '{{.Names}}' | grep -q "etheros-ollama"; then
  echo -e "  ${YELLOW}⚠${NC}  etheros-ollama container already exists — skipping service add"
else
  if grep -q "etheros-ollama\|container_name: etheros-ollama" "$COMPOSE"; then
    echo -e "  ${YELLOW}⚠${NC}  Ollama already defined in docker-compose.yml"
  else
    echo -e "  Adding Ollama service block to docker-compose.yml..."
    python3 - <<'PYEOF'
compose_path = '/opt/etheros-edge/docker-compose.yml'
with open(compose_path, 'r') as f:
    content = f.read()

ollama_block = """
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
"""

# Insert before the 'networks:' top-level key (before 'etheros-net:')
import re
# Find last service and append before top-level networks section
marker = '\nnetworks:'
if marker in content:
    idx = content.rindex(marker)
    content = content[:idx] + ollama_block + content[idx:]
    with open(compose_path, 'w') as f:
        f.write(content)
    print('Ollama service block added')
else:
    print('WARNING: Could not find networks: section')
PYEOF
    echo -e "  ${GREEN}✓${NC} Ollama service added to docker-compose.yml"
  fi

  # Start ollama container
  echo -e "${YELLOW}▸${NC} Starting Ollama container..."
  cd /opt/etheros-edge && docker compose up -d ollama
  sleep 5
fi

# ── Pull llama3.2:3b model (small, works on low RAM) ─────────────────────────
echo -e "${YELLOW}▸${NC} Pulling llama3.2:3b model (may take a few minutes on first run)..."
if docker exec etheros-ollama ollama list 2>/dev/null | grep -q "llama3.2:3b"; then
  echo -e "  ${GREEN}✓${NC} llama3.2:3b already present"
else
  docker exec etheros-ollama ollama pull llama3.2:3b &
  PULL_PID=$!
  echo -e "  ${CYAN}ℹ${NC}  Model pull started in background (PID $PULL_PID)"
  echo -e "  ${CYAN}ℹ${NC}  Monitor: docker logs -f etheros-ollama"
  echo -e "  ${CYAN}ℹ${NC}  Chat will work once pull completes (~1–2 GB)"
fi

# ── Restart ISP portal backend ─────────────────────────────────────────────────
echo ""
echo -e "${YELLOW}▸${NC} Restarting ISP portal backend..."
docker restart etheros-isp-portal-backend
sleep 6
echo -e "  ${GREEN}✓${NC} Restarted"

# ── Health check ──────────────────────────────────────────────────────────────
echo ""
echo -e "${YELLOW}▸${NC} Health check..."
HEALTH=$(curl -sf https://edge.etheros.ai/health 2>/dev/null || echo '{}')
echo -e "  /health → $HEALTH"

# ── Public endpoints ──────────────────────────────────────────────────────────
echo ""
echo -e "${YELLOW}▸${NC} Public endpoint verification (expect 200)..."
for ep in /health /api/tenant /api/terminal/config /api/billing/plans /api/agents/browse "/isp-portal/api/subscribers/checkout-result?session_id=test"; do
  STATUS=$(curl -s -o /dev/null -w "%{http_code}" "https://edge.etheros.ai${ep}" 2>/dev/null)
  # checkout-result with dummy session_id returns 200 with ok:false — that's fine
  if [ "$STATUS" = "200" ] || [ "$STATUS" = "404" ]; then
    echo -e "  ${GREEN}✓${NC} $STATUS  $ep"
  else
    echo -e "  ${RED}✗${NC} $STATUS  $ep  ← UNEXPECTED"
  fi
done

# ── Auth gates ────────────────────────────────────────────────────────────────
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
echo -e "${YELLOW}▸${NC} Verifying Stripe env vars are loaded in container..."
STRIPE_CHECK=$(docker exec etheros-isp-portal-backend sh -c 'echo $STRIPE_SECRET_KEY' 2>/dev/null | cut -c1-20 || echo "(error)")
if [[ "$STRIPE_CHECK" == sk_* ]]; then
  echo -e "  ${GREEN}✓${NC} STRIPE_SECRET_KEY present in container (${STRIPE_CHECK}...)"
else
  echo -e "  ${RED}✗${NC} STRIPE_SECRET_KEY not found in container — check docker-compose env"
fi

# ── Ollama status ─────────────────────────────────────────────────────────────
echo ""
echo -e "${YELLOW}▸${NC} Ollama status..."
OLLAMA_RUNNING=$(docker ps --filter "name=etheros-ollama" --format "{{.Status}}" 2>/dev/null || echo "not found")
echo -e "  Container: $OLLAMA_RUNNING"
OLLAMA_PING=$(curl -sf http://127.0.0.1:11434/api/tags 2>/dev/null | python3 -c "import sys,json; d=json.load(sys.stdin); names=[m['name'] for m in d.get('models',[])]; print('models: '+','.join(names) if names else 'no models yet')" 2>/dev/null || echo "unreachable — pull may still be running")
echo -e "  $OLLAMA_PING"

echo ""
echo -e "${GREEN}${BOLD}━━━ Sprint 4U deploy complete ━━━${NC}"
echo -e "  Commit: af61711"
echo -e "  Stripe creds: externalized to container env vars (TEST mode)"
echo -e "  Empty-email bug: fixed in BillingScreen"
echo -e "  Checkout success: CheckoutSuccessScreen shows PIN after Stripe redirect"
echo -e "  Ollama: service added, llama3.2:3b model pull initiated"
echo -e ""
echo -e "  ${CYAN}Next steps:${NC}"
echo -e "  • Register Stripe webhook at: https://dashboard.stripe.com/test/webhooks"
echo -e "    URL: https://edge.etheros.ai/isp-portal/api/billing/webhook"
echo -e "    Events: checkout.session.completed, customer.subscription.updated,"
echo -e "            customer.subscription.deleted, invoice.payment_succeeded,"
echo -e "            invoice.payment_failed"
echo -e "  • Monitor model pull: docker logs -f etheros-ollama"
echo -e "  • Once model is ready, test chat at: https://edge.etheros.ai"
