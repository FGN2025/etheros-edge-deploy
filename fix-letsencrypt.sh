#!/usr/bin/env bash
set -euo pipefail

EDGE_DIR="/opt/etheros-edge"
NGINX_CONF="$EDGE_DIR/nginx/conf.d/etheros-edge.conf"
LE_LIVE="/etc/letsencrypt/live/edge.etheros.ai"

echo "[EtherOS] Switching Nginx to Let's Encrypt certificate for edge.etheros.ai"

# 1. Mount the Let's Encrypt dir into the Nginx container by updating docker-compose.yml
COMPOSE="$EDGE_DIR/docker-compose.yml"

# Patch the nginx volumes section to include letsencrypt (idempotent check)
if grep -q "letsencrypt" "$COMPOSE"; then
  echo "[EtherOS] docker-compose.yml already has letsencrypt mount, skipping patch"
else
  echo "[EtherOS] Adding letsencrypt volume mount to etheros-nginx in docker-compose.yml"
  sed -i '/etheros-nginx:/,/^  [a-z]/{/- \.\/nginx\/.ssl:\/etc\/nginx\/ssl/a\      - /etc/letsencrypt:/etc/letsencrypt:ro
  }' "$COMPOSE"
fi

# 2. Update Nginx config to use Let's Encrypt paths
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
    server_name edge.etheros.ai;
    return 301 https://$host$request_uri;
}

# Main HTTPS server - Let's Encrypt cert
server {
    listen 443 ssl;
    server_name edge.etheros.ai;

    ssl_certificate     /etc/letsencrypt/live/edge.etheros.ai/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/edge.etheros.ai/privkey.pem;
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_ciphers         HIGH:!aNULL:!MD5;
    ssl_session_cache   shared:SSL:10m;
    ssl_session_timeout 10m;

    client_max_body_size 100M;
    proxy_read_timeout   300s;
    proxy_send_timeout   300s;

    # Ollama OpenAI-compat endpoint
    location /ollama/v1/ {
        rewrite ^/ollama/v1/(.*)$ /v1/$1 break;
        proxy_pass         http://ollama_backend;
        proxy_set_header   Host $host;
        proxy_set_header   X-Real-IP $remote_addr;
        proxy_set_header   X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto $scheme;
    }

    # Ollama native API
    location /ollama/api/ {
        rewrite ^/ollama/api/(.*)$ /api/$1 break;
        proxy_pass         http://ollama_backend;
        proxy_set_header   Host $host;
        proxy_set_header   X-Real-IP $remote_addr;
        proxy_set_header   X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto $scheme;
    }

    # Open WebUI API
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

    # Open WebUI WebSocket
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

# mTLS port for EtherOS PC clients
server {
    listen 8443 ssl;
    server_name edge.etheros.ai;

    ssl_certificate     /etc/letsencrypt/live/edge.etheros.ai/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/edge.etheros.ai/privkey.pem;
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

# 3. Recreate the nginx container so it picks up the new volume mount + config
echo "[EtherOS] Recreating etheros-nginx container with Let's Encrypt mount..."
cd "$EDGE_DIR"
docker compose up -d --no-deps --force-recreate etheros-nginx

echo "[EtherOS] Waiting 3s for Nginx to start..."
sleep 3

# 4. Test
echo -n "  HTTPS test (edge.etheros.ai):  "
curl -s https://edge.etheros.ai/api/config -o /dev/null -w "%{http_code}\n" || echo "failed (DNS may still be propagating)"

echo -n "  HTTPS test (localhost):        "
curl -sk https://localhost/api/config -o /dev/null -w "%{http_code}\n" || echo "failed"

echo ""
echo "[EtherOS] Let's Encrypt cert active."
echo "   EtherOS AI:  https://edge.etheros.ai/"
echo "   Grafana:     https://edge.etheros.ai/grafana/"
echo "   Ollama API:  https://edge.etheros.ai/ollama/api/"
echo ""
echo "[EtherOS] Auto-renewal is handled by certbot.timer (systemd)."
echo "   Verify with: systemctl status certbot.timer"
