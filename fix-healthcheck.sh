#!/bin/bash
# EtherOS — Fix Ollama healthcheck (no curl in container, use wget on /)
set -e
E=/opt/etheros-edge
cd $E

echo "[1/3] Rewriting Ollama healthcheck in docker-compose.yml..."

# Replace the entire ollama healthcheck block
python3 - << 'PYEOF'
import re

with open('/opt/etheros-edge/docker-compose.yml', 'r') as f:
    content = f.read()

# Replace ollama healthcheck test line
old = '      test: ["CMD","curl","-sf","http://localhost:11434/api/tags"]'
new = '      test: ["CMD","sh","-c","wget -qO- http://localhost:11434/ > /dev/null 2>&1 || exit 1"]'
content = content.replace(old, new)

# Set generous timings
content = re.sub(r'(  ollama:.*?healthcheck:.*?interval: )\S+', lambda m: m.group(0).replace(m.group(0).split()[-1], '15s'), content, flags=re.DOTALL)

with open('/opt/etheros-edge/docker-compose.yml', 'w') as f:
    f.write(content)

print('docker-compose.yml updated.')
PYEOF

echo "[2/3] Stopping all containers..."
docker compose down --remove-orphans 2>/dev/null || true
docker rm -f etheros-ollama etheros-open-webui etheros-nginx etheros-prometheus etheros-grafana etheros-model-loader 2>/dev/null || true

echo "[3/3] Starting stack..."
docker compose up -d

echo ""
echo "Waiting 20s for containers to initialize..."
sleep 20

docker compose ps
echo ""
echo "Direct Ollama check (from host):"
curl -sf http://localhost:11434/ && echo "Ollama responding OK" || echo "Ollama not yet on host port - check binding"
curl -sf http://localhost:11434/api/tags | python3 -c "import sys,json; d=json.load(sys.stdin); print('Models loaded:', len(d.get('models',[])))" 2>/dev/null || echo "(no models yet - normal before pull)"
