#!/bin/bash
# EtherOS — Fix Nginx: proxy_pass must use Docker container names, not 127.0.0.1
set -e
E=/opt/etheros-edge

echo "Rewriting Nginx vhost with correct Docker upstream addresses..."

cat > $E/nginx/conf.d/etheros-edge.conf << 'VHEOF'
server {
  listen 80 default_server;
  server_name _;
  location /health {
    return 200 '{"status":"ok"}';
    add_header Content-Type application/json;
  }
  location / { return 301 https://$host$request_uri; }
}

server {
  listen 443 ssl;
  listen 8443 ssl;
  server_name _;

  ssl_certificate        /etc/nginx/ssl/edge-server.crt;
  ssl_certificate_key    /etc/nginx/ssl/edge-server.key;
  ssl_client_certificate /etc/nginx/ssl/etheros-ca.crt;
  ssl_verify_client      optional;
  ssl_protocols          TLSv1.3 TLSv1.2;
  ssl_prefer_server_ciphers off;
  ssl_session_cache      shared:SSL:50m;
  ssl_session_timeout    1d;
  ssl_session_tickets    off;

  add_header Strict-Transport-Security "max-age=63072000" always;
  add_header X-Frame-Options "SAMEORIGIN" always;
  add_header X-Content-Type-Options "nosniff" always;

  # Ollama OpenAI-compatible API
  location /v1/ {
    proxy_pass         http://etheros-ollama:11434/v1/;
    proxy_http_version 1.1;
    proxy_set_header   Host $host;
    proxy_set_header   X-Real-IP $remote_addr;
    proxy_set_header   Connection "";
    proxy_buffering    off;
    proxy_read_timeout 300s;
    chunked_transfer_encoding on;
  }

  # Ollama native API
  location /api/ {
    proxy_pass         http://etheros-ollama:11434/api/;
    proxy_http_version 1.1;
    proxy_set_header   Host $host;
    proxy_set_header   X-Real-IP $remote_addr;
    proxy_set_header   Connection "";
    proxy_buffering    off;
    proxy_read_timeout 300s;
    chunked_transfer_encoding on;
  }

  # Grafana
  location /grafana/ {
    proxy_pass         http://etheros-grafana:3000/;
    proxy_http_version 1.1;
    proxy_set_header   Host $host;
    proxy_set_header   X-Real-IP $remote_addr;
    proxy_set_header   X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header   X-Forwarded-Proto $scheme;
  }

  # Open WebUI (catch-all)
  location / {
    proxy_pass         http://etheros-open-webui:8080/;
    proxy_http_version 1.1;
    proxy_set_header   Host $host;
    proxy_set_header   X-Real-IP $remote_addr;
    proxy_set_header   Upgrade $http_upgrade;
    proxy_set_header   Connection "upgrade";
    proxy_buffering    off;
    proxy_read_timeout 300s;
  }

  location /health {
    access_log off;
    return 200 '{"status":"ok","node":"etheros-edge"}';
    add_header Content-Type application/json;
  }
}
VHEOF

echo "Reloading Nginx..."
docker exec etheros-nginx nginx -t && docker exec etheros-nginx nginx -s reload

echo ""
echo "Waiting 10s for Open WebUI to be ready..."
sleep 10

echo "Testing upstream connections:"
docker exec etheros-nginx wget -qO- http://etheros-ollama:11434/ > /dev/null 2>&1 && echo "Ollama: reachable from Nginx" || echo "Ollama: not reachable"
docker exec etheros-nginx wget -qO- http://etheros-open-webui:8080/health > /dev/null 2>&1 && echo "Open WebUI: reachable from Nginx" || echo "Open WebUI: still starting (wait 60s and refresh browser)"
docker exec etheros-nginx wget -qO- http://etheros-grafana:3000/api/health > /dev/null 2>&1 && echo "Grafana: reachable from Nginx" || echo "Grafana: check logs"

echo ""
echo "Done. Try https://72.62.160.72/ in your browser now."
