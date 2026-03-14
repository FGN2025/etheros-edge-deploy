#!/bin/bash
# EtherOS — Fix Ollama health check and restart stack
set -e
E=/opt/etheros-edge

echo "[1/3] Updating Ollama health check timing in docker-compose.yml..."
cd $E

# Update just the ollama healthcheck section with more generous timings
sed -i 's/start_period: 60s/start_period: 120s/' docker-compose.yml
sed -i 's/retries: 5/retries: 10/' docker-compose.yml

echo "[2/3] Stopping and removing unhealthy containers..."
docker compose down --remove-orphans 2>/dev/null || true

echo "[3/3] Restarting stack with fixed timings..."
docker compose up -d

echo ""
echo "Waiting 30s for Ollama to initialize..."
sleep 30

docker compose ps
echo ""
echo "Checking Ollama directly:"
docker exec etheros-ollama curl -sf http://localhost:11434/api/tags 2>/dev/null && echo "Ollama is UP" || echo "Ollama still starting - wait 60s more and run: docker compose ps"
