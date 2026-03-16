#!/bin/bash
# ─────────────────────────────────────────────────────────────
# deploy-sprint-4g.sh  —  Sprint 4G: Subscriber Billing Self-Service
# Deploys:
#   • ISP portal frontend bundle (BillingScreen + HomeScreen billing button)
#   • ISP portal backend server.js (upgrade / cancel / reactivate endpoints + webhook sync)
# ─────────────────────────────────────────────────────────────
set -e

REMOTE="root@72.62.160.72"
REPO_RAW="https://raw.githubusercontent.com/FGN2025/etheros-edge-deploy/main"
EDGE_DIR="/opt/etheros-edge"

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Sprint 4G — Billing Self-Service  "
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

echo ""
echo "Step 1/6 — Deploy backend (server.js) …"
ssh "$REMOTE" "curl -fsSL '${REPO_RAW}/backends/isp-portal/server.js' \
  -o ${EDGE_DIR}/backends/isp-portal/server.js"

echo "Step 2/6 — Deploy JS bundle …"
ssh "$REMOTE" "curl -fsSL '${REPO_RAW}/static/isp-portal/assets/index-C7zmkj-Z.js' \
  -o ${EDGE_DIR}/static/isp-portal/assets/index-C7zmkj-Z.js"

echo "Step 3/6 — Deploy CSS bundle …"
ssh "$REMOTE" "curl -fsSL '${REPO_RAW}/static/isp-portal/assets/index-DqLRA3je.css' \
  -o ${EDGE_DIR}/static/isp-portal/assets/index-DqLRA3je.css"

echo "Step 4/6 — Deploy index.html …"
ssh "$REMOTE" "curl -fsSL '${REPO_RAW}/static/isp-portal/index.html' \
  -o ${EDGE_DIR}/static/isp-portal/index.html"

echo "Step 5/6 — Remove stale bundles …"
ssh "$REMOTE" "find ${EDGE_DIR}/static/isp-portal/assets/ -name 'index-*' \
  ! -name 'index-C7zmkj-Z.js' ! -name 'index-DqLRA3je.css' -delete && \
  echo 'Stale bundles removed.'"

echo "Step 6/6 — Restart ISP portal backend …"
ssh "$REMOTE" "cd ${EDGE_DIR} && docker compose restart etheros-isp-portal-backend && \
  echo 'Container restarted.'"

echo ""
echo "✓ Sprint 4G deployed successfully"
echo "  Live: https://edge.etheros.ai/"
echo "  → Sign in as a subscriber → My Plan & Billing"
