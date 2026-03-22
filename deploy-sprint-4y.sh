#!/bin/bash
# Sprint 4Y — Silent retry on chat stream error, then toast
# Hot-swap static JS bundle only (no container restart needed)

set -e
STATIC="/opt/etheros-edge/static/isp-portal"
REPO="https://raw.githubusercontent.com/FGN2025/etheros-edge-deploy/main"

echo "=== Sprint 4Y: Chat silent retry + toast ==="

echo "[1/3] Pulling new JS bundle..."
curl -fsSL -o "$STATIC/assets/index-DLBe0prN.js" "$REPO/static/isp-portal/assets/index-DLBe0prN.js"
echo "      index-DLBe0prN.js deployed"

echo "[2/3] Removing old bundle(s)..."
rm -f "$STATIC/assets/index-DvEz5EPQ.js"
rm -f "$STATIC/assets/index-DKKZbzQF.js"
echo "      Old bundles removed"

echo "[3/3] Updating index.html..."
curl -fsSL -o "$STATIC/index.html" "$REPO/static/isp-portal/index.html"
echo "      index.html updated"

echo ""
echo "=== Done! Chat now silently retries once before showing error toast ==="
