#!/bin/bash
# Sprint 4Z — Fix "Full chat ↗" to open agent's specific model in Open WebUI
# Hot-swap static JS bundle only (no container restart needed)

set -e
STATIC="/opt/etheros-edge/static/isp-portal"
REPO="https://raw.githubusercontent.com/FGN2025/etheros-edge-deploy/main"

echo "=== Sprint 4Z: Full chat opens agent-specific model ==="

echo "[1/3] Pulling new JS bundle..."
curl -fsSL -o "$STATIC/assets/index-B6xlMmxY.js" "$REPO/static/isp-portal/assets/index-B6xlMmxY.js"
echo "      index-B6xlMmxY.js deployed"

echo "[2/3] Removing old bundle..."
rm -f "$STATIC/assets/index-DLBe0prN.js"
rm -f "$STATIC/assets/index-DKKZbzQF.js"
rm -f "$STATIC/assets/index-DvEz5EPQ.js"
echo "      Old bundles removed"

echo "[3/3] Updating index.html..."
curl -fsSL -o "$STATIC/index.html" "$REPO/static/isp-portal/index.html"
echo "      index.html updated"

echo ""
echo "=== Done! Full chat ↗ now opens Open WebUI pre-loaded with the agent's model ==="
echo "Example: Farm & Ranch Advisor → opens edge.etheros.ai:8080/?models=llama3.2%3A3b"
