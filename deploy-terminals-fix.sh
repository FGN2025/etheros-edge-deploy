#!/bin/bash
set -e

STATIC=/opt/etheros-edge/static/isp-portal/assets
RAW=https://raw.githubusercontent.com/FGN2025/etheros-edge-deploy/main

echo "=== Deploying /terminals fix ==="

# Remove ALL old JS bundles
rm -f $STATIC/index-hBm7xWNm.js \
      $STATIC/index-B8BEq77P.js \
      $STATIC/index-Bu9EqVyL.js \
      $STATIC/index-C0JUMHRb.js

# Pull new JS bundle
curl -sSf "$RAW/static/isp-portal/assets/index-C-R7PzJa.js" -o $STATIC/index-C-R7PzJa.js

# Update index.html so it references the new bundle
curl -sSf "$RAW/static/isp-portal/index.html" -o /opt/etheros-edge/static/isp-portal/index.html

echo "Assets:"
ls /opt/etheros-edge/static/isp-portal/assets/

echo ""
echo "index.html references:"
grep -o "index-[^\"]*" /opt/etheros-edge/static/isp-portal/index.html

echo ""
echo "Done — no restart needed (static files served directly by nginx)"
