#!/usr/bin/env bash
set -euo pipefail

EDGE_DIR="/opt/etheros-edge"

echo "[EtherOS] Re-disabling signup now that admin account exists..."

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

env["ENABLE_SIGNUP"] = "false"
svc["environment"] = env

with open("/opt/etheros-edge/docker-compose.yml", "w") as f:
    yaml.dump(data, f, default_flow_style=False, sort_keys=False)

print("[EtherOS] ENABLE_SIGNUP set back to false")
with open("/tmp/etheros_webui_svc", "w") as f:
    f.write(webui_key)
PYEOF

WEBUI_SVC=$(cat /tmp/etheros_webui_svc)
cd "$EDGE_DIR"
docker compose up -d --no-deps --force-recreate "$WEBUI_SVC"
sleep 3
echo "[EtherOS] Signup disabled. Only admins can now invite users."
