#!/usr/bin/env bash
set -euo pipefail

EDGE_DIR="/opt/etheros-edge"

echo "[EtherOS] Re-enabling signup for admin account creation..."

python3 << 'PYEOF'
import yaml, sys

with open("/opt/etheros-edge/docker-compose.yml", "r") as f:
    data = yaml.safe_load(f)

services = data.get("services", {})
webui_key = None
for k in services:
    if "webui" in k.lower() or "open-webui" in k.lower():
        webui_key = k
        break

svc = services[webui_key]
env = svc.get("environment", {})
if isinstance(env, list):
    env_dict = {}
    for item in env:
        if "=" in item:
            k2, v = item.split("=", 1)
            env_dict[k2] = v
    env = env_dict

env["ENABLE_SIGNUP"] = "true"
env.pop("WEBUI_URL", None)
svc["environment"] = env

with open("/opt/etheros-edge/docker-compose.yml", "w") as f:
    yaml.dump(data, f, default_flow_style=False, sort_keys=False)

print("[EtherOS] ENABLE_SIGNUP=true, WEBUI_URL removed")
with open("/tmp/etheros_webui_svc", "w") as f:
    f.write(webui_key)
PYEOF

WEBUI_SVC=$(cat /tmp/etheros_webui_svc)
cd "$EDGE_DIR"
docker compose up -d --no-deps --force-recreate "$WEBUI_SVC"

echo "[EtherOS] Waiting for Open WebUI to become ready..."
for i in $(seq 1 24); do
  CODE=$(curl -sk https://localhost/api/config -o /dev/null -w "%{http_code}" 2>/dev/null || echo "000")
  if [ "$CODE" = "200" ]; then
    echo ""
    echo "[EtherOS] Open WebUI is ready (HTTP $CODE)"
    break
  fi
  echo -n "  attempt $i: HTTP $CODE - waiting 5s..."
  sleep 5
  echo ""
done

echo ""
echo "============================================================"
echo "  Open WebUI is ready. Create your admin account NOW at:"
echo ""
echo "    https://edge.etheros.ai/"
echo ""
echo "  After you have successfully logged in, run:"
echo "    curl -fsSL https://raw.githubusercontent.com/FGN2025/etheros-edge-deploy/main/fix-disable-signup.sh | bash"
echo "============================================================"
