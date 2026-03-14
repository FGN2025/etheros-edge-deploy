#!/bin/bash
set -e
E=/opt/etheros-edge
apt-get update -qq && apt-get install -y -qq curl openssl ufw
command -v docker || curl -fsSL https://get.docker.com | sh
systemctl enable docker && systemctl start docker
mkdir -p $E/{nginx/conf.d,nginx/ssl,prometheus,grafana/provisioning/{datasources,dashboards},certs/{etheros-ca,edge-server}}
# CA
openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-384 -out $E/certs/etheros-ca/etheros-ca.key && chmod 400 $E/certs/etheros-ca/etheros-ca.key
openssl req -new -x509 -key $E/certs/etheros-ca/etheros-ca.key -out $E/certs/etheros-ca/etheros-ca.crt -days 3650 -subj "/C=US/ST=Arizona/O=Fiber Gaming Network/CN=EtherOS Root CA" -addext "basicConstraints=critical,CA:true,pathlen:1" -addext "keyUsage=critical,keyCertSign,cRLSign"
# Edge server cert
openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out $E/certs/edge-server/edge-server.key && chmod 400 $E/certs/edge-server/edge-server.key
openssl req -new -key $E/certs/edge-server/edge-server.key -out $E/certs/edge-server/edge-server.csr -subj "/C=US/ST=Arizona/O=Fiber Gaming Network/CN=72.62.160.72"
printf '[v3_req]\nsubjectAltName=IP:72.62.160.72,DNS:srv1491974.hstgr.cloud,DNS:localhost,IP:127.0.0.1\nkeyUsage=critical,digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth\nbasicConstraints=CA:false\n' > /tmp/san.cnf
openssl x509 -req -in $E/certs/edge-server/edge-server.csr -CA $E/certs/etheros-ca/etheros-ca.crt -CAkey $E/certs/etheros-ca/etheros-ca.key -CAcreateserial -out $E/certs/edge-server/edge-server.crt -days 825 -extfile /tmp/san.cnf -extensions v3_req
cp $E/certs/etheros-ca/etheros-ca.crt $E/nginx/ssl/ && cp $E/certs/edge-server/edge-server.{crt,key} $E/nginx/ssl/ && chmod 640 $E/nginx/ssl/*.key
# Nginx main config
cat > $E/nginx/nginx.conf << 'EOF'
user nginx;
worker_processes auto;
error_log /var/log/nginx/error.log warn;
pid /var/run/nginx.pid;
events { worker_connections 4096; use epoll; multi_accept on; }
http {
  include /etc/nginx/mime.types;
  default_type application/octet-stream;
  sendfile on; tcp_nopush on; tcp_nodelay on;
  keepalive_timeout 75s; client_max_body_size 100m; server_tokens off;
  gzip on; gzip_vary on; gzip_proxied any; gzip_comp_level 6;
  gzip_types text/plain text/css application/json application/javascript text/javascript;
  limit_req_zone $binary_remote_addr zone=terminal:10m rate=30r/s;
  limit_req_zone $binary_remote_addr zone=webui:10m rate=10r/s;
  include /etc/nginx/conf.d/*.conf;
}
EOF
# Nginx vhost
cat > $E/nginx/conf.d/etheros-edge.conf << 'EOF'
server {
  listen 80 default_server; server_name _;
  location /health { return 200 '{"status":"ok"}'; add_header Content-Type application/json; }
  location / { return 301 https://$host$request_uri; }
}
server {
  listen 443 ssl; listen 8443 ssl; server_name _;
  ssl_certificate /etc/nginx/ssl/edge-server.crt;
  ssl_certificate_key /etc/nginx/ssl/edge-server.key;
  ssl_client_certificate /etc/nginx/ssl/etheros-ca.crt;
  ssl_verify_client optional;
  ssl_protocols TLSv1.3 TLSv1.2;
  ssl_prefer_server_ciphers off;
  ssl_session_cache shared:SSL:50m; ssl_session_timeout 1d; ssl_session_tickets off;
  add_header Strict-Transport-Security "max-age=63072000" always;
  add_header X-Frame-Options "SAMEORIGIN" always;
  add_header X-Content-Type-Options "nosniff" always;
  location /v1/ {
    limit_req zone=terminal burst=50 nodelay;
    proxy_pass http://127.0.0.1:11434/v1/;
    proxy_http_version 1.1; proxy_set_header Host $host;
    proxy_set_header Connection ""; proxy_buffering off;
    proxy_read_timeout 300s; chunked_transfer_encoding on;
  }
  location /api/ {
    limit_req zone=terminal burst=50 nodelay;
    proxy_pass http://127.0.0.1:11434/api/;
    proxy_http_version 1.1; proxy_set_header Host $host;
    proxy_set_header Connection ""; proxy_buffering off;
    proxy_read_timeout 300s; chunked_transfer_encoding on;
  }
  location /grafana/ {
    proxy_pass http://127.0.0.1:3001/;
    proxy_http_version 1.1; proxy_set_header Host $host;
    proxy_set_header X-Forwarded-Proto $scheme;
  }
  location / {
    limit_req zone=webui burst=20 nodelay;
    proxy_pass http://127.0.0.1:3000/;
    proxy_http_version 1.1; proxy_set_header Host $host;
    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection "upgrade";
    proxy_buffering off; proxy_read_timeout 300s;
  }
  location /health {
    access_log off;
    return 200 '{"status":"ok","node":"etheros-edge"}';
    add_header Content-Type application/json;
  }
}
EOF
# Prometheus
cat > $E/prometheus/prometheus.yml << 'EOF'
global:
  scrape_interval: 15s
  evaluation_interval: 15s
  external_labels:
    edge_node: 'etheros-edge-001'
scrape_configs:
  - job_name: prometheus
    static_configs:
      - targets: ['localhost:9090']
  - job_name: ollama
    scrape_interval: 30s
    static_configs:
      - targets: ['ollama:11434']
    metrics_path: /metrics
EOF
# Grafana
cat > $E/grafana/provisioning/datasources/prometheus.yml << 'EOF'
apiVersion: 1
datasources:
  - name: Prometheus
    type: prometheus
    access: proxy
    url: http://prometheus:9090
    isDefault: true
    editable: false
EOF
cat > $E/grafana/provisioning/dashboards/etheros-dashboards.yml << 'EOF'
apiVersion: 1
providers:
  - name: EtherOS
    orgId: 1
    type: file
    disableDeletion: false
    updateIntervalSeconds: 30
    options:
      path: /etc/grafana/provisioning/dashboards
EOF
# Docker Compose
cat > $E/docker-compose.yml << 'EOF'
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
    healthcheck:
      test: ["CMD","curl","-sf","http://localhost:11434/api/tags"]
      interval: 30s
      timeout: 10s
      retries: 5
      start_period: 60s
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
        until curl -sf http://ollama:11434/api/tags > /dev/null 2>&1; do sleep 5; done
        ollama pull phi3:mini && ollama pull nomic-embed-text && echo "Models ready."
    depends_on:
      ollama:
        condition: service_healthy
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
      ollama:
        condition: service_healthy
    healthcheck:
      test: ["CMD","curl","-sf","http://localhost:8080/health"]
      interval: 30s
      timeout: 5s
      retries: 5
      start_period: 90s
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
    depends_on: [open-webui, ollama]
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
    depends_on: [prometheus]
EOF
# Firewall
ufw --force reset && ufw default deny incoming && ufw default allow outgoing && ufw allow ssh && ufw allow 80/tcp && ufw allow 443/tcp && ufw allow 8443/tcp && ufw --force enable
# Launch
cd $E && docker compose pull && docker compose up -d
echo ""
echo "============================================"
echo "  EtherOS Edge Node DEPLOYED"
echo "  Open WebUI: https://72.62.160.72/"
echo "  Ollama API: https://72.62.160.72:8443/v1/"
echo "  Grafana:    https://72.62.160.72/grafana/"
echo "  Grafana pw: EtherOS-Admin-2026"
echo "============================================"
docker compose ps
