#!/usr/bin/env bash
set -euo pipefail

EDGE_DIR="/opt/etheros-edge"
COMPOSE="$EDGE_DIR/docker-compose.yml"

echo "[EtherOS] Fixing Open WebUI first-run admin registration..."

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

if not webui_key:
    print(f"ERROR: No open-webui service found. Services: {list(services.keys())}")
    sys.exit(1)

print(f"[EtherOS] Found open-webui service key: '{webui_key}'")

svc = services[webui_key]
env = svc.get("environment", {})

if isinstance(env, list):
    env_dict = {}
    for item in env:
        if "=" in item:
            k, v = item.split("=", 1)
            env_dict[k] = v
        else:
            env_dict[item] = None
    env = env_dict

env["ENABLE_SIGNUP"] = "true"
env["WEBUI_AUTH"] = "true"
env.pop("WEBUI_URL", None)

svc["environment"] = env
print(f"[EtherOS] Set ENABLE_SIGNUP=true, removed WEBUI_URL")

with open("/opt/etheros-edge/docker-compose.yml", "w") as f:
    yaml.dump(data, f, default_flow_style=False, sort_keys=False)

print("[EtherOS] docker-compose.yml updated successfully")

with open("/tmp/etheros_webui_svc", "w") as f:
    f.write(webui_key)
PYEOF

WEBUI_SVC=$(cat /tmp/etheros_webui_svc)
echo ""
echo "[EtherOS] Recreating '$WEBUI_SVC' container..."
cd "$EDGE_DIR"
docker compose up -d --no-deps --force-recreate "$WEBUI_SVC"

echo "[EtherOS] Waiting 5s for Open WebUI to restart..."
sleep 5

echo ""
echo -n "  /api/config status: "
curl -sk https://localhost/api/config -o /dev/null -w "%{http_code}\n" || echo "failed"

echo ""
echo "[EtherOS] Done. Open WebUI restarted with ENABLE_SIGNUP=true"
echo ""
echo "  --> Go to https://edge.etheros.ai/ and create your admin account now."
echo "  --> After logging in, run fix-disable-signup.sh to lock it back down."
