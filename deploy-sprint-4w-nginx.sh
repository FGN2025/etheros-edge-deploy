#!/bin/bash
# Sprint 4W — Fix Open WebUI blank page: proxy /_app/ /static/ /manifest.json
# Open WebUI emits absolute asset paths — nginx must proxy them to the container

set -e
REPO="https://raw.githubusercontent.com/FGN2025/etheros-edge-deploy/main"
NGINX_CONF="/opt/etheros-edge/nginx/conf.d/etheros-edge.conf"

echo "==> Updating nginx config..."
curl -fsSL -o "$NGINX_CONF" "$REPO/nginx/conf.d/etheros-edge.conf"

echo "==> Testing nginx config..."
docker exec etheros-nginx nginx -t

echo "==> Reloading nginx..."
docker exec etheros-nginx nginx -s reload

echo ""
echo "Done. Visit https://edge.etheros.ai/chat/"
