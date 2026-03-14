#!/usr/bin/env bash
set -euo pipefail

EDGE_DIR="/opt/etheros-edge"
NGINX_CONF="$EDGE_DIR/nginx/conf.d/etheros-edge.conf"

echo "[EtherOS] Fixing Nginx routing - separating Open WebUI /api/ from Ollama /api/"

# Write corrected Nginx config
# Key changes:
#   /ollama/v1/  -> Ollama OpenAI-compat endpoint (renamed from /v1/)
#   /ollama/api/ -> Ollama native API (renamed from /api/)
#   /api/        -> Open WebUI backend API (was wrongly pointing to Ollama)
#   /grafana/    -> Grafana (unchanged)
#   /            -> Open WebUI frontend (unchanged)

cat > "$NGINX_CONF" << 'NGINX'
upstream open_webui {
    server etheros-open-webui:8080;
}

upstream ollama_backend {
    server etheros-ollama:11434;
}

upstream grafana_backend {
    server etheros-grafana:3000;
}

upstream prometheus_backend {
    server etheros-prometheus:9090;
}

# HTTP -> HTTPS redirect
server {
    listen 80;
    server_name _;
    return 301 https://$host$request_uri;
}

# Main HTTPS server
server {
    listen 443 ssl;
    server_name _;

    ssl_certificate     /etc/nginx/ssl/edge-server.crt;
    ssl_certificate_key /etc/nginx/ssl/edge-server.key;
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_ciphers         HIGH:!aNULL:!MD5;

    client_max_body_size 100M;
    proxy_read_timeout   300s;
    proxy_send_timeout   300s;

    # Ollama OpenAI-compat endpoint (for external API clients)
    location /ollama/v1/ {
        rewrite ^/ollama/v1/(.*)$ /v1/$1 break;
        proxy_pass         http://ollama_backend;
        proxy_set_header   Host $host;
        proxy_set_header   X-Real-IP $remote_addr;
        proxy_set_header   X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto $scheme;
    }

    # Ollama native API (for external API clients)
    location /ollama/api/ {
        rewrite ^/ollama/api/(.*)$ /api/$1 break;
        proxy_pass         http://ollama_backend;
        proxy_set_header   Host $host;
        proxy_set_header   X-Real-IP $remote_addr;
        proxy_set_header   X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto $scheme;
    }

    # Open WebUI API (MUST come before / catch-all)
    location /api/ {
        proxy_pass         http://open_webui;
        proxy_set_header   Host $host;
        proxy_set_header   X-Real-IP $remote_addr;
        proxy_set_header   X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto $scheme;
        proxy_http_version 1.1;
        proxy_set_header   Upgrade $http_upgrade;
        proxy_set_header   Connection "upgrade";
    }

    # Open WebUI WebSocket (for streaming responses)
    location /ws/ {
        proxy_pass         http://open_webui;
        proxy_http_version 1.1;
        proxy_set_header   Upgrade $http_upgrade;
        proxy_set_header   Connection "upgrade";
        proxy_set_header   Host $host;
        proxy_set_header   X-Real-IP $remote_addr;
        proxy_set_header   X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto $scheme;
        proxy_read_timeout 3600s;
    }

    # Grafana
    location /grafana/ {
        proxy_pass         http://grafana_backend/;
        proxy_set_header   Host $host;
        proxy_set_header   X-Real-IP $remote_addr;
        proxy_set_header   X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto $scheme;
    }

    # Open WebUI frontend (catch-all)
    location / {
        proxy_pass         http://open_webui;
        proxy_set_header   Host $host;
        proxy_set_header   X-Real-IP $remote_addr;
        proxy_set_header   X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto $scheme;
        proxy_http_version 1.1;
        proxy_set_header   Upgrade $http_upgrade;
        proxy_set_header   Connection "upgrade";
    }
}

# mTLS port for EtherOS PC clients (optional, future use)
server {
    listen 8443 ssl;
    server_name _;

    ssl_certificate     /etc/nginx/ssl/edge-server.crt;
    ssl_certificate_key /etc/nginx/ssl/edge-server.key;
    ssl_client_certificate /etc/nginx/ssl/etheros-ca.crt;
    ssl_verify_client   optional;
    ssl_protocols       TLSv1.2 TLSv1.3;

    location /v1/ {
        proxy_pass http://ollama_backend/v1/;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Client-Verified $ssl_client_verify;
        proxy_set_header X-Client-DN $ssl_client_s_dn;
    }
}
NGINX

echo "[EtherOS] Reloading Nginx..."
docker exec etheros-nginx nginx -t && docker exec etheros-nginx nginx -s reload

echo ""
echo "[EtherOS] Done. Testing endpoints..."
sleep 2

echo -n "  /api/config from host:  "
curl -sk https://localhost/api/config -o /dev/null -w "%{http_code}\n" || echo "failed"

echo -n "  / (WebUI frontend):      "
curl -sk https://localhost/ -o /dev/null -w "%{http_code}\n" || echo "failed"

echo ""
echo "[EtherOS] Nginx routing fixed."
echo "   Open WebUI:  https://72.62.160.72/"
echo "   Ollama API:  https://72.62.160.72/ollama/api/"
echo "   Grafana:     https://72.62.160.72/grafana/"
