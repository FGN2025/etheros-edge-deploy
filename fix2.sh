#!/bin/bash
# EtherOS — Fix: remove healthcheck blocks, start all services directly
set -e
E=/opt/etheros-edge
cd $E

echo "Stopping all containers..."
docker compose down --remove-orphans 2>/dev/null || true

echo "Rewriting docker-compose.yml without healthcheck dependencies..."
cat > $E/docker-compose.yml << 'DCEOF'
name: etheros-edge

networks:
  edge-internal:
    driver: bridge
  edge-public:
    driver: bridge

volumes:
  ollama-data:
  open-webui-data:
  prometheus-data:
  grafana-data:

services:

  ollama:
    image: ollama/ollama:latest
    container_name: etheros-ollama
    restart: unless-stopped
    networks: [edge-internal]
    volumes:
      - ollama-data:/root/.ollama
    environment:
      - OLLAMA_HOST=0.0.0.0:11434
      - OLLAMA_NUM_PARALLEL=2
      - OLLAMA_MAX_LOADED_MODELS=1
      - OLLAMA_KEEP_ALIVE=5m
    ports:
      - "127.0.0.1:11434:11434"

  ollama-model-loader:
    image: ollama/ollama:latest
    container_name: etheros-model-loader
    restart: on-failure
    networks: [edge-internal]
    volumes:
      - ollama-data:/root/.ollama
    entrypoint: ["/bin/sh","-c"]
    command:
      - |
        echo "Waiting for Ollama..."
        until wget -qO- http://ollama:11434/ > /dev/null 2>&1; do
          echo "  not ready yet, retrying..."
          sleep 5
        done
        echo "Ollama ready. Pulling models..."
        ollama pull phi3:mini
        ollama pull nomic-embed-text
        echo "Models ready."
    depends_on:
      - ollama

  open-webui:
    image: ghcr.io/open-webui/open-webui:main
    container_name: etheros-open-webui
    restart: unless-stopped
    networks: [edge-internal]
    volumes:
      - open-webui-data:/app/backend/data
    environment:
      - OLLAMA_BASE_URL=http://ollama:11434
      - WEBUI_SECRET_KEY=etheros-fgn-secret-key-2026-change-me
      - WEBUI_URL=https://72.62.160.72
      - ENABLE_SIGNUP=false
      - DEFAULT_USER_ROLE=user
      - ENABLE_COMMUNITY_SHARING=false
      - WEBUI_NAME=EtherOS AI
    ports:
      - "127.0.0.1:3000:8080"
    depends_on:
      - ollama

  nginx:
    image: nginx:1.25-alpine
    container_name: etheros-nginx
    restart: unless-stopped
    networks: [edge-internal, edge-public]
    ports:
      - "80:80"
      - "443:443"
      - "8443:8443"
    volumes:
      - /opt/etheros-edge/nginx/nginx.conf:/etc/nginx/nginx.conf:ro
      - /opt/etheros-edge/nginx/conf.d:/etc/nginx/conf.d:ro
      - /opt/etheros-edge/nginx/ssl:/etc/nginx/ssl:ro
    depends_on:
      - open-webui

  prometheus:
    image: prom/prometheus:latest
    container_name: etheros-prometheus
    restart: unless-stopped
    networks: [edge-internal]
    volumes:
      - /opt/etheros-edge/prometheus/prometheus.yml:/etc/prometheus/prometheus.yml:ro
      - prometheus-data:/prometheus
    command:
      - --config.file=/etc/prometheus/prometheus.yml
      - --storage.tsdb.path=/prometheus
      - --storage.tsdb.retention.time=30d
    ports:
      - "127.0.0.1:9090:9090"

  grafana:
    image: grafana/grafana:latest
    container_name: etheros-grafana
    restart: unless-stopped
    networks: [edge-internal]
    volumes:
      - grafana-data:/var/lib/grafana
      - /opt/etheros-edge/grafana/provisioning:/etc/grafana/provisioning:ro
    environment:
      - GF_SECURITY_ADMIN_PASSWORD=EtherOS-Admin-2026
      - GF_SECURITY_ADMIN_USER=admin
      - GF_SERVER_DOMAIN=72.62.160.72
      - GF_SERVER_ROOT_URL=https://72.62.160.72/grafana
      - GF_SERVER_SERVE_FROM_SUB_PATH=true
      - GF_ANALYTICS_REPORTING_ENABLED=false
    ports:
      - "127.0.0.1:3001:3000"
    depends_on:
      - prometheus
DCEOF

echo "Starting stack (no healthcheck dependencies)..."
docker compose up -d

echo ""
echo "Waiting 15s..."
sleep 15

docker compose ps

echo ""
echo "--- Direct service checks ---"
curl -sf http://localhost:11434/ && echo "Ollama: UP" || echo "Ollama: not yet ready (normal - wait 30s)"
curl -sf http://localhost:3000/health && echo "Open WebUI: UP" || echo "Open WebUI: starting..."
curl -sf http://localhost/health && echo "Nginx: UP" || echo "Nginx: check logs"
echo ""
echo "============================================"
echo "  EtherOS Edge Node running at 72.62.160.72"
echo "  Open WebUI : https://72.62.160.72/"
echo "  Ollama API : https://72.62.160.72:8443/v1/"
echo "  Grafana    : https://72.62.160.72/grafana/"
echo "  Grafana pw : EtherOS-Admin-2026"
echo "============================================"
