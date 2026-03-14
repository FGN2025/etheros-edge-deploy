#!/bin/bash
# EtherOS — Fix 'Open WebUI Backend Required' error
# Cause: WEBUI_URL mismatch + missing CORS/backend env vars
set -e
E=/opt/etheros-edge
cd $E

echo "Updating Open WebUI environment in docker-compose.yml..."

# Patch the open-webui service environment block
python3 << 'PYEOF'
import re

with open('/opt/etheros-edge/docker-compose.yml', 'r') as f:
    content = f.read()

# Replace the open-webui environment block
old_env = """    environment:
      - OLLAMA_BASE_URL=http://ollama:11434
      - WEBUI_SECRET_KEY=etheros-fgn-secret-key-2026-change-me
      - WEBUI_URL=https://72.62.160.72
      - ENABLE_SIGNUP=false
      - DEFAULT_USER_ROLE=user
      - ENABLE_COMMUNITY_SHARING=false
      - WEBUI_NAME=EtherOS AI"""

new_env = """    environment:
      - OLLAMA_BASE_URL=http://etheros-ollama:11434
      - WEBUI_SECRET_KEY=etheros-fgn-secret-key-2026-change-me
      - WEBUI_URL=https://72.62.160.72
      - CORS_ALLOW_ORIGIN=*
      - ENABLE_SIGNUP=false
      - DEFAULT_USER_ROLE=user
      - ENABLE_COMMUNITY_SHARING=false
      - WEBUI_NAME=EtherOS AI
      - WEBUI_AUTH=true
      - GLOBAL_LOG_LEVEL=INFO"""

if old_env in content:
    content = content.replace(old_env, new_env)
    print('Environment updated.')
else:
    print('Block not found - check manually')

with open('/opt/etheros-edge/docker-compose.yml', 'w') as f:
    f.write(content)
PYEOF

echo "Restarting Open WebUI container..."
docker compose stop open-webui
docker compose rm -f open-webui
docker compose up -d open-webui

echo ""
echo "Waiting 60s for Open WebUI to fully initialize..."
for i in $(seq 1 12); do
    sleep 5
    STATUS=$(docker inspect etheros-open-webui --format='{{.State.Status}}' 2>/dev/null || echo 'unknown')
    printf "  [%ds] Container status: %s\n" $((i*5)) "$STATUS"
    if docker exec etheros-nginx wget -qO- http://etheros-open-webui:8080/ > /dev/null 2>&1; then
        echo "  Open WebUI is responding!"
        break
    fi
done

echo ""
docker compose ps
echo ""
echo "Try https://72.62.160.72/ in your browser now."
echo "If you still see the error, run: docker logs etheros-open-webui --tail 30"
