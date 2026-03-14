#!/usr/bin/env bash
set -euo pipefail

EDGE_DIR="/opt/etheros-edge"
NGINX_CONF="$EDGE_DIR/nginx/conf.d/etheros-edge.conf"
COMPOSE="$EDGE_DIR/docker-compose.yml"
LE_LIVE="/etc/letsencrypt/live/edge.etheros.ai"

echo "[EtherOS] === Current docker-compose.yml nginx service section ==="
grep -A 30 "nginx" "$COMPOSE" | head -40
echo ""
echo "[EtherOS] === All service names in compose file ==="
grep "^  [a-zA-Z]" "$COMPOSE" | grep -v "^  #" || true
echo ""

echo "[EtherOS] Checking letsencrypt mount status..."
if grep -q "letsencrypt" "$COMPOSE"; then
  echo "  letsencrypt already in compose (but may be malformed - checking...)"
  grep -n "letsencrypt" "$COMPOSE"
else
  echo "  letsencrypt NOT in compose"
fi
echo ""

# Use Python to safely patch the YAML instead of sed
python3 << 'PYEOF'
import yaml, sys, copy

with open("/opt/etheros-edge/docker-compose.yml", "r") as f:
    raw = f.read()

# Parse
data = yaml.safe_load(raw)

# Find the nginx service (name may vary)
services = data.get("services", {})
nginx_key = None
for k in services:
    if "nginx" in k.lower():
        nginx_key = k
        break

if not nginx_key:
    print(f"ERROR: No nginx service found. Services: {list(services.keys())}")
    sys.exit(1)

print(f"[EtherOS] Found nginx service key: '{nginx_key}'")

svc = services[nginx_key]
volumes = svc.get("volumes", [])

# Check if already mounted
already = any("letsencrypt" in str(v) for v in volumes)
if already:
    volumes = [v for v in volumes if "letsencrypt" not in str(v)]
    print("[EtherOS] Removed existing (possibly malformed) letsencrypt mount")

volumes.append("/etc/letsencrypt:/etc/letsencrypt:ro")
svc["volumes"] = volumes
print(f"[EtherOS] Added /etc/letsencrypt:/etc/letsencrypt:ro to '{nginx_key}' volumes")

with open("/opt/etheros-edge/docker-compose.yml", "w") as f:
    yaml.dump(data, f, default_flow_style=False, sort_keys=False)

print("[EtherOS] docker-compose.yml written successfully")
print(f"[EtherOS] Nginx service name for docker compose: '{nginx_key}'")

# Write the nginx service name to a temp file for bash to read
with open("/tmp/etheros_nginx_svc", "w") as f:
    f.write(nginx_key)
PYEOF

NGINX_SVC=$(cat /tmp/etheros_nginx_svc)
echo ""
echo "[EtherOS] Nginx service name: '$NGINX_SVC'"

# Update Nginx config to use Let's Encrypt paths
echo "[EtherOS] Writing updated Nginx config..."
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

    location /ollama/v1/ {
        rewrite ^/ollama/v1/(.*)$ /v1/$1 break;
        proxy_pass         http://ollama_backend;
        proxy_set_header   Host $host;
        proxy_set_header   X-Real-IP $remote_addr;
        proxy_set_header   X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto $scheme;
    }

    location /ollama/api/ {
        rewrite ^/ollama/api/(.*)$ /api/$1 break;
        proxy_pass         http://ollama_backend;
        proxy_set_header   Host $host;
        proxy_set_header   X-Real-IP $remote_addr;
        proxy_set_header   X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto $scheme;
    }

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

    location /grafana/ {
        proxy_pass         http://grafana_backend/;
        proxy_set_header   Host $host;
        proxy_set_header   X-Real-IP $remote_addr;
        proxy_set_header   X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto $scheme;
    }

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

echo "[EtherOS] Recreating '$NGINX_SVC' container..."
cd "$EDGE_DIR"
docker compose up -d --no-deps --force-recreate "$NGINX_SVC"

echo "[EtherOS] Waiting 3s..."
sleep 3

echo ""
echo -n "  HTTPS localhost test: "
curl -sk https://localhost/api/config -o /dev/null -w "%{http_code}\n" || echo "failed"

echo -n "  HTTPS domain test:    "
curl -s --max-time 5 https://edge.etheros.ai/api/config -o /dev/null -w "%{http_code}\n" 2>/dev/null || echo "failed (DNS may still propagating)"

echo ""
echo "[EtherOS] Done."
echo "  https://edge.etheros.ai/"
