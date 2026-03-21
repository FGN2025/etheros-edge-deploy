#!/bin/bash
# Sprint 4W Final — Open WebUI on port 8080 (clean root access)
# - Reverts WEBUI_BASE_URL (no longer needed)
# - Cleans up nginx: removes all /chat/ /auth /error /api/ Open WebUI hacks
# - Adds new :8080 SSL server block for Open WebUI at /
# - Updates ISP portal JS bundle (Full chat button → :8080)
# - Opens port 8080 in firewall

set -e
REPO="https://raw.githubusercontent.com/FGN2025/etheros-edge-deploy/main"
STATIC="/opt/etheros-edge/static/isp-portal"
OVERRIDE="/opt/etheros-edge/docker-compose.override.yml"

echo "==> [1/5] Reverting WEBUI_BASE_URL from override..."
sed -i '/WEBUI_BASE_URL/d' "$OVERRIDE"
# Remove open-webui service block if now empty
python3 - <<'PYEOF'
with open("/opt/etheros-edge/docker-compose.override.yml") as f:
    lines = f.readlines()
# Remove trailing empty open-webui: environment: block
cleaned = []
i = 0
while i < len(lines):
    # Skip bare "  open-webui:" lines followed only by "    environment:" with nothing under them
    if lines[i].strip() == 'open-webui:' and i+1 < len(lines) and lines[i+1].strip() == 'environment:':
        # Check if next line after environment: is another service or EOF
        if i+2 >= len(lines) or (not lines[i+2].startswith('      -')):
            i += 2  # skip both lines
            continue
    cleaned.append(lines[i])
    i += 1
with open("/opt/etheros-edge/docker-compose.override.yml", "w") as f:
    f.writelines(cleaned)
print("Override cleaned.")
PYEOF

echo "==> [2/5] Updating nginx config..."
curl -fsSL -o /opt/etheros-edge/nginx/conf.d/etheros-edge.conf \
  "$REPO/nginx/conf.d/etheros-edge.conf"

echo "==> [3/5] Testing nginx config..."
docker exec etheros-nginx nginx -t

echo "==> [4/5] Reloading nginx..."
docker exec etheros-nginx nginx -s reload

echo "==> [5/5] Deploying new ISP portal JS bundle..."
curl -fsSL -o "$STATIC/assets/index-DMQbzvrZ.js" \
  "$REPO/static/isp-portal/assets/index-DMQbzvrZ.js"
rm -f "$STATIC/assets/index-DKKZbzQF.js"
curl -fsSL -o "$STATIC/index.html" \
  "$REPO/static/isp-portal/index.html"

echo ""
echo "==> Opening port 8080 in firewall..."
ufw allow 8080/tcp 2>/dev/null && echo "    ufw: port 8080 opened" || \
  iptables -I INPUT -p tcp --dport 8080 -j ACCEPT 2>/dev/null && echo "    iptables: port 8080 opened" || \
  echo "    (firewall rule may already exist or not needed)"

echo ""
echo "Done."
echo "  ISP Portal : https://edge.etheros.ai/"
echo "  Open WebUI : https://edge.etheros.ai:8080/"
