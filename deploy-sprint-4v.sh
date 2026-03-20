#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════════
# EtherOS — Sprint 4V Deploy: Transactional Email + PIN Recovery
#
# Changes deployed:
#   - routes/email.js: Resend helper (sendPinWelcomeEmail, sendPinRecoveryEmail)
#   - server.js: PIN welcome email on free-path signup
#   - billing.js: PIN welcome email fires on checkout.session.completed webhook
#   - server.js: POST /api/subscribers/pin-recovery (rate-limited 5/min, no enum)
#   - terminal.tsx: "Forgot your PIN?" → email entry → confirmation on PinScreen
#   - Frontend bundle: index-DnxUwKku.js + index-BPnk-9iC.css
#
# Run on VPS:
#   RESEND_API_KEY=re_... bash <(curl -fsSL https://raw.githubusercontent.com/FGN2025/etheros-edge-deploy/e171360/deploy-sprint-4v.sh)
# ═══════════════════════════════════════════════════════════════════════════════
set -euo pipefail

GREEN='\033[0;32m'; CYAN='\033[0;36m'; YELLOW='\033[1;33m'; BOLD='\033[1m'; RED='\033[0;31m'; NC='\033[0m'
REPO="https://raw.githubusercontent.com/FGN2025/etheros-edge-deploy/main"
BACKEND="/opt/etheros-edge/backends/isp-portal"
ROUTES="$BACKEND/routes"
STATIC="/opt/etheros-edge/static/isp-portal"
EDGE_DIR="/opt/etheros-edge"

echo -e "${CYAN}${BOLD}━━━ EtherOS Sprint 4V — Transactional Email ━━━${NC}"
echo ""

# ── Collect Resend API key ────────────────────────────────────────────────────
if [ -z "${RESEND_API_KEY:-}" ]; then
  printf "  Enter RESEND_API_KEY (re_...): "
  read -r RESEND_API_KEY
fi

# ── Pull updated backend files ─────────────────────────────────────────────────
echo -e "${YELLOW}▸${NC} Pulling backend files..."
curl -fsSL "$REPO/backends/isp-portal/server.js"          -o "$BACKEND/server.js"
curl -fsSL "$REPO/backends/isp-portal/routes/billing.js"  -o "$ROUTES/billing.js"
curl -fsSL "$REPO/backends/isp-portal/routes/email.js"    -o "$ROUTES/email.js"
echo -e "  ${GREEN}✓${NC} server.js + billing.js + email.js"

# ── Pull updated frontend bundle ───────────────────────────────────────────────
echo -e "${YELLOW}▸${NC} Updating frontend static bundle..."
mkdir -p "$STATIC/assets"
curl -fsSL "$REPO/static/isp-portal/index.html"                   -o "$STATIC/index.html"
curl -fsSL "$REPO/static/isp-portal/assets/index-DnxUwKku.js"    -o "$STATIC/assets/index-DnxUwKku.js"
curl -fsSL "$REPO/static/isp-portal/assets/index-BPnk-9iC.css"   -o "$STATIC/assets/index-BPnk-9iC.css"
rm -f "$STATIC/assets/index-kZ53NXg-.js" "$STATIC/assets/index-D37hKAr6.css"
echo -e "  ${GREEN}✓${NC} Static bundle updated (index-DnxUwKku.js)"

# ── Inject RESEND_API_KEY into docker-compose.override.yml ────────────────────
echo -e "${YELLOW}▸${NC} Updating docker-compose.override.yml with Resend key..."
OVERRIDE_FILE="$EDGE_DIR/docker-compose.override.yml"

if [ ! -f "$OVERRIDE_FILE" ]; then
  echo -e "  ${RED}✗${NC} docker-compose.override.yml not found — run deploy-sprint-4u.sh first"
  exit 1
fi

# Add RESEND_API_KEY to the override if not already present
if grep -q "RESEND_API_KEY" "$OVERRIDE_FILE"; then
  echo -e "  ${YELLOW}⚠${NC}  RESEND_API_KEY already in override — updating value..."
  python3 -c "
import re, sys
path = '$OVERRIDE_FILE'
key = sys.argv[1]
with open(path) as f: content = f.read()
content = re.sub(r'- RESEND_API_KEY=.*', f'- RESEND_API_KEY={key}', content)
with open(path, 'w') as f: f.write(content)
print('updated')
" "$RESEND_API_KEY"
else
  # Append after STRIPE_WEBHOOK_SECRET line
  python3 -c "
import sys
path = '$OVERRIDE_FILE'
key = sys.argv[1]
with open(path) as f: content = f.read()
old = '      - STRIPE_WEBHOOK_SECRET='
new_line = f'      - RESEND_API_KEY={key}'
# Insert after the last env var line in isp-portal-backend block
lines = content.splitlines()
insert_after = -1
for i, line in enumerate(lines):
    if 'STRIPE_WEBHOOK_SECRET=' in line:
        insert_after = i
        break
if insert_after >= 0:
    lines.insert(insert_after + 1, new_line)
    with open(path, 'w') as f: f.write('\n'.join(lines) + '\n')
    print('inserted')
else:
    print('WARNING: could not find insertion point', file=sys.stderr)
    sys.exit(1)
" "$RESEND_API_KEY"
fi
echo -e "  ${GREEN}✓${NC} RESEND_API_KEY added to override"

# ── Recreate isp-portal-backend to pick up new env var ────────────────────────
echo ""
echo -e "${YELLOW}▸${NC} Recreating isp-portal-backend..."
cd "$EDGE_DIR"
docker compose up -d --no-deps --force-recreate isp-portal-backend
sleep 6
echo -e "  ${GREEN}✓${NC} Recreated"

# ── Health check ──────────────────────────────────────────────────────────────
echo ""
echo -e "${YELLOW}▸${NC} Health check..."
HEALTH=$(curl -sf https://edge.etheros.ai/health 2>/dev/null || echo '{}')
echo -e "  /health → $HEALTH"

# ── Endpoint verification ──────────────────────────────────────────────────────
echo ""
echo -e "${YELLOW}▸${NC} New endpoint verification..."

# pin-recovery should accept POST (returns 400 without body, not 404)
RECOVERY_STATUS=$(curl -s -o /dev/null -w "%{http_code}" -X POST \
  https://edge.etheros.ai/isp-portal/api/subscribers/pin-recovery \
  -H "Content-Type: application/json" -d '{}' 2>/dev/null)
if [ "$RECOVERY_STATUS" = "400" ]; then
  echo -e "  ${GREEN}✓${NC} 400 (expected — no email body)  /api/subscribers/pin-recovery"
elif [ "$RECOVERY_STATUS" = "200" ]; then
  echo -e "  ${GREEN}✓${NC} 200  /api/subscribers/pin-recovery"
else
  echo -e "  ${RED}✗${NC} $RECOVERY_STATUS  /api/subscribers/pin-recovery  ← UNEXPECTED"
fi

# Auth gates
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

# ── Verify Resend key in container ────────────────────────────────────────────
echo ""
echo -e "${YELLOW}▸${NC} Verifying Resend env var in container..."
RESEND_CHECK=$(docker exec etheros-isp-portal-backend sh -c 'echo $RESEND_API_KEY' 2>/dev/null | cut -c1-8 || echo "(error)")
if [[ "$RESEND_CHECK" == re_* ]]; then
  echo -e "  ${GREEN}✓${NC} RESEND_API_KEY present (${RESEND_CHECK}...)"
else
  echo -e "  ${RED}✗${NC} RESEND_API_KEY not found in container"
fi

echo ""
echo -e "${GREEN}${BOLD}━━━ Sprint 4V deploy complete ━━━${NC}"
echo -e "  Commit: e171360"
echo -e ""
echo -e "  ${CYAN}What's live:${NC}"
echo -e "  • PIN welcome email sent on free-path subscriber signup"
echo -e "  • PIN email sent on Stripe checkout.session.completed webhook"
echo -e "  • POST /api/subscribers/pin-recovery — forgotten PIN email"
echo -e "  • Terminal: 'Forgot your PIN?' link on sign-in screen"
echo -e ""
echo -e "  ${YELLOW}Next step — register Stripe webhook:${NC}"
echo -e "  1. Go to https://dashboard.stripe.com/test/webhooks"
echo -e "  2. Add endpoint: https://edge.etheros.ai/isp-portal/api/billing/webhook"
echo -e "  3. Events: checkout.session.completed, customer.subscription.updated,"
echo -e "             customer.subscription.deleted, invoice.payment_succeeded,"
echo -e "             invoice.payment_failed"
echo -e "  4. Copy the new whsec_... secret and update STRIPE_WEBHOOK_SECRET in"
echo -e "     /opt/etheros-edge/docker-compose.override.yml, then:"
echo -e "     docker compose up -d --no-deps --force-recreate isp-portal-backend"
echo -e ""
echo -e "  ${YELLOW}Test the full flow:${NC}"
echo -e "  • Sign up a subscriber (no Stripe) → should receive welcome email"
echo -e "  • Use 'Forgot PIN?' on terminal sign-in → should receive PIN email"
