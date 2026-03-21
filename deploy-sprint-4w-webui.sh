#!/bin/bash
# Sprint 4W — Fix Open WebUI blank page at /chat/
# Appends open-webui service block with WEBUI_BASE_URL=/chat
# to docker-compose.override.yml (existing secrets untouched)

set -e
OVERRIDE="/opt/etheros-edge/docker-compose.override.yml"

echo "==> Checking for existing WEBUI_BASE_URL..."
if grep -q "WEBUI_BASE_URL" "$OVERRIDE"; then
  echo "    Already set — skipping file edit."
else
  echo "==> Appending open-webui env block..."
  cat >> "$OVERRIDE" << 'EOF'
  open-webui:
    environment:
      - WEBUI_BASE_URL=/chat
EOF
  echo "    Done."
fi

echo ""
echo "==> Current override:"
cat "$OVERRIDE"

echo ""
echo "==> Restarting open-webui container..."
cd /opt/etheros-edge
docker compose up -d --no-deps --force-recreate open-webui

echo "==> Waiting 15s for startup..."
sleep 15
docker compose ps open-webui

echo ""
echo "Done. Visit https://edge.etheros.ai/chat/"
