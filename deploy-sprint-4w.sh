#!/bin/bash
# Sprint 4W — Fix "Full chat ↗" button opening admin login
# Changes: window.open('/') → window.open('/chat/') in terminal.tsx (3 places)
# Only JS bundle changed (new hash); CSS is the same.

set -e
REPO="https://raw.githubusercontent.com/FGN2025/etheros-edge-deploy/main"
STATIC="/opt/etheros-edge/static/isp-portal"

echo "==> Deploying new JS bundle..."
curl -fsSL -o "$STATIC/assets/index-DKKZbzQF.js" \
  "$REPO/static/isp-portal/assets/index-DKKZbzQF.js"

echo "==> Removing old JS bundle..."
rm -f "$STATIC/assets/index-8ZlzVA--.js"

echo "==> Updating index.html..."
curl -fsSL -o "$STATIC/index.html" \
  "$REPO/static/isp-portal/index.html"

echo "==> Done. No container restart needed."
echo "    Test: click 'Full chat ↗' — should open https://edge.etheros.ai/chat/ in new tab"
