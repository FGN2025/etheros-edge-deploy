#!/usr/bin/env bash
set -euo pipefail

EDGE_DIR="/opt/etheros-edge"
COMPOSE="$EDGE_DIR/docker-compose.yml"

echo "[EtherOS] Fixing model-loader to wait for Ollama before pulling models..."

python3 << 'PYEOF'
import yaml, sys

with open("/opt/etheros-edge/docker-compose.yml", "r") as f:
    data = yaml.safe_load(f)

services = data.get("services", {})

loader_key = None
for k in services:
    if "loader" in k.lower() or "model" in k.lower():
        loader_key = k
        break

if not loader_key:
    print(f"ERROR: No model-loader service found. Services: {list(services.keys())}")
    sys.exit(1)

print(f"[EtherOS] Found model-loader service key: '{loader_key}'")

svc = services[loader_key]

svc["command"] = [
    "/bin/sh", "-c",
    (
        "echo '[model-loader] Waiting for Ollama...' && "
        "until ollama list > /dev/null 2>&1; do echo '[model-loader] Ollama not ready, retrying in 5s...'; sleep 5; done && "
        "echo '[model-loader] Ollama ready. Pulling phi3:mini...' && "
        "ollama pull phi3:mini && "
        "echo '[model-loader] Pulling nomic-embed-text...' && "
        "ollama pull nomic-embed-text && "
        "echo '[model-loader] All models pulled successfully.' && "
        "ollama list"
    )
]

env = svc.get("environment", {})
if isinstance(env, list):
    env_dict = {}
    for item in env:
        if "=" in item:
            k2, v = item.split("=", 1)
            env_dict[k2] = v
    env = env_dict
env["OLLAMA_HOST"] = "http://etheros-ollama:11434"
svc["environment"] = env
svc["restart"] = "on-failure"

with open("/opt/etheros-edge/docker-compose.yml", "w") as f:
    yaml.dump(data, f, default_flow_style=False, sort_keys=False)

print(f"[EtherOS] Model-loader updated with retry loop and OLLAMA_HOST env var")
with open("/tmp/etheros_loader_svc", "w") as f:
    f.write(loader_key)
PYEOF

LOADER_SVC=$(cat /tmp/etheros_loader_svc)
echo ""
echo "[EtherOS] Restarting '$LOADER_SVC' (models already cached, will be fast)..."
cd "$EDGE_DIR"
docker compose up -d --no-deps --force-recreate "$LOADER_SVC"

sleep 3
echo "[EtherOS] Loader logs:"
docker logs "etheros-$LOADER_SVC" --tail 10 2>/dev/null || docker logs "etheros-model-loader" --tail 10 2>/dev/null || true

echo ""
echo "[EtherOS] Model-loader fixed. Current models:"
docker exec etheros-ollama ollama list
