#!/usr/bin/env bash
# ══════════════════════════════════════════════════════════════════════════════
#  EtherOS — Fix Chat Streaming (Two-Part Fix)
#
#  Part 1: Fix wrong notebook connector on CDL Skills Development agent
#          Agent 1350abe4 had nb-cc2657f1 (Rural Broadband KB) attached.
#          That connector's notebook fetch was hanging and eating the 6s timeout.
#          Correct connector is nb-240ad8b4 (CDL Skills Development).
#
#  Part 2: Add nginx SSE buffering fix for /marketplace/api/
#          Without proxy_buffering off, nginx buffers SSE chunks until the
#          connection closes — so the browser sees nothing until all done.
#
#  Run as: bash <(curl -fsSL https://raw.githubusercontent.com/FGN2025/etheros-edge-deploy/main/fix-chat-stream.sh)
# ══════════════════════════════════════════════════════════════════════════════
set -euo pipefail

echo ""
echo "══════════════════════════════════════════════════════"
echo "  EtherOS Chat Streaming Fix"
echo "══════════════════════════════════════════════════════"
echo ""

AGENTS_FILE="/opt/etheros-edge/data/agents.json"
NGINX_CONF="/opt/etheros-edge/nginx/conf.d/etheros-edge.conf"

# ── Part 1: Fix the wrong notebook connector ─────────────────────────────────
echo "▸ Part 1: Fixing notebook connector on CDL Skills Development agent..."

python3 << 'PYEOF'
import json, sys, os

agents_file = '/opt/etheros-edge/data/agents.json'

if not os.path.exists(agents_file):
    print(f"  ⚠  {agents_file} not found — backend may not have written it yet")
    print("     Will patch server.js seed data instead...")
    sys.exit(1)

with open(agents_file, 'r') as f:
    agents = json.load(f)

fixed = 0
for agent in agents:
    agent_id = agent.get('id', '')
    slug = agent.get('slug', '')
    # Target the CDL Skills Development agent — match by ID or slug
    if agent_id == '1350abe4' or slug == 'cdl-skills-development':
        current = agent.get('notebookConnectorIds', [])
        print(f"  Found: {agent_id} ({slug})")
        print(f"  Current connectors: {current}")
        # Fix: replace wrong connector with correct one
        agent['notebookConnectorIds'] = ['nb-240ad8b4']
        print(f"  Fixed:  {agent['notebookConnectorIds']}")
        fixed += 1

if fixed == 0:
    print("  ⚠  CDL Skills Development agent not found in agents.json by ID/slug")
    # Try to fix any agent that has the wrong connector
    for agent in agents:
        connectors = agent.get('notebookConnectorIds', [])
        if 'nb-cc2657f1' in connectors:
            print(f"  Found wrong connector on: {agent.get('id')} ({agent.get('slug')})")
            agent['notebookConnectorIds'] = [c for c in connectors if c != 'nb-cc2657f1']
            print(f"  Removed nb-cc2657f1 from connectors")
            fixed += 1

with open(agents_file, 'w') as f:
    json.dump(agents, f, indent=2)

print(f"  ✓ Saved agents.json ({fixed} agent(s) updated)")
PYEOF

# If the above Python exited with error (no agents.json), patch the seed in server.js
if [ $? -ne 0 ]; then
  echo "  ▸ Falling back to server.js seed patch..."
  python3 << 'PYEOF2'
with open('/opt/etheros-edge/backends/marketplace/server.js', 'r') as f:
    src = f.read()

# Fix the wrong connector in seed data
old = "notebookConnectorIds: ['nb-cc2657f1']"
new = "notebookConnectorIds: ['nb-240ad8b4']"
if old in src:
    src = src.replace(old, new)
    with open('/opt/etheros-edge/backends/marketplace/server.js', 'w') as f:
        f.write(src)
    print("  ✓ Patched server.js seed: nb-cc2657f1 → nb-240ad8b4")
else:
    print("  ⚠  Could not find nb-cc2657f1 in server.js — may already be correct")
PYEOF2
fi

echo "  ✓ Notebook connector fix complete"
echo ""

# ── Part 2: nginx SSE buffering fix ─────────────────────────────────────────
echo "▸ Part 2: Patching nginx for SSE streaming (proxy_buffering off)..."

python3 << 'PYEOF3'
import re

conf_path = '/opt/etheros-edge/nginx/conf.d/etheros-edge.conf'

with open(conf_path, 'r') as f:
    content = f.read()

# Check if already patched
if 'proxy_buffering off' in content and '/marketplace/api/' in content:
    # Find the marketplace/api block and check if it has buffering off
    match = re.search(r'location /marketplace/api/ \{[^}]+\}', content, re.DOTALL)
    if match:
        block = match.group(0)
        if 'proxy_buffering' in block:
            print("  ✓ nginx /marketplace/api/ already has SSE headers — no change needed")
            exit(0)

# New /marketplace/api/ location block with SSE support
new_marketplace_api = '''    location /marketplace/api/ {
        proxy_pass http://etheros-marketplace-backend:3011/api/;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;

        # SSE streaming — must disable buffering or browser gets nothing until EOF
        proxy_buffering off;
        proxy_cache off;
        proxy_set_header X-Accel-Buffering no;
        proxy_read_timeout 300s;
        proxy_connect_timeout 10s;
        chunked_transfer_encoding on;
    }'''

# Replace the existing /marketplace/api/ block
old_block_pattern = r'    location /marketplace/api/ \{[^}]+\}'
if re.search(old_block_pattern, content, re.DOTALL):
    content = re.sub(old_block_pattern, new_marketplace_api, content, count=1, flags=re.DOTALL)
    print("  ✓ Replaced /marketplace/api/ block with SSE-enabled version")
else:
    print("  ⚠  /marketplace/api/ block not found — inserting before /marketplace/health")
    # Insert before health check
    insert_before = '    location /marketplace/health {'
    if insert_before in content:
        content = content.replace(insert_before, new_marketplace_api + '\n\n' + insert_before)
        print("  ✓ Inserted /marketplace/api/ SSE block")
    else:
        print("  ✗ ERROR: Could not find insertion point in nginx config")
        exit(1)

with open(conf_path, 'w') as f:
    f.write(content)

print("  ✓ nginx config updated")
PYEOF3

echo ""
echo "▸ Testing nginx config syntax..."
docker exec etheros-nginx nginx -t 2>&1 | tail -5

echo ""
echo "▸ Reloading nginx (no downtime)..."
docker exec etheros-nginx nginx -s reload
sleep 2
echo "  ✓ nginx reloaded"

echo ""
echo "▸ Restarting marketplace backend to reload agents from disk..."
docker restart etheros-marketplace-backend
sleep 5

echo ""
echo "▸ Verifying backend health..."
for i in 1 2 3 4 5; do
  STATUS=$(curl -sf -o /dev/null -w "%{http_code}" http://localhost:3011/api/agents 2>/dev/null || echo "FAIL")
  if [ "$STATUS" = "200" ]; then
    echo "  ✓ Backend responding (HTTP 200)"
    break
  fi
  echo "  Waiting... ($i/5)"
  sleep 2
done

echo ""
echo "▸ Verifying CDL agent connector..."
python3 << 'PYEOF4'
import json, subprocess, urllib.request

# Check via API
try:
    with urllib.request.urlopen('http://localhost:3011/api/agents', timeout=5) as resp:
        agents = json.loads(resp.read())
    cdl = next((a for a in agents if a.get('id') == '1350abe4' or a.get('slug') == 'cdl-skills-development'), None)
    if cdl:
        connectors = cdl.get('notebookConnectorIds', [])
        print(f"  CDL agent: {cdl['id']} ({cdl['slug']})")
        print(f"  Connectors: {connectors}")
        if 'nb-240ad8b4' in connectors and 'nb-cc2657f1' not in connectors:
            print("  ✓ Correct connector (nb-240ad8b4 = CDL Skills Development)")
        elif 'nb-cc2657f1' in connectors:
            print("  ✗ STILL has wrong connector nb-cc2657f1!")
        else:
            print(f"  ⚠  Unexpected connectors: {connectors}")
    else:
        print("  ⚠  CDL Skills Development agent not found in API response")
        for a in agents:
            print(f"     - {a.get('id')} {a.get('slug')}")
except Exception as e:
    print(f"  ✗ Could not reach backend: {e}")
PYEOF4

echo ""
echo "▸ Testing SSE stream through nginx (should see tokens)..."
echo "  (Waiting up to 20s for first token from CDL agent...)"
timeout 20 curl -s -N \
  -X POST "http://localhost/marketplace/api/agents/1350abe4/chat/stream" \
  -H "Content-Type: application/json" \
  -H "Host: edge.etheros.ai" \
  -d '{"messages":[{"role":"user","content":"What is a CDL license?"}]}' \
  2>/dev/null | head -c 400 || echo "(timeout or no tokens)"

echo ""
echo ""
echo "══════════════════════════════════════════════════════"
echo "  Chat Streaming Fix Applied!"
echo "══════════════════════════════════════════════════════"
echo ""
echo "  Changes:"
echo "  ✓ CDL agent connector: nb-cc2657f1 → nb-240ad8b4"
echo "    (Rural Broadband KB → CDL Skills Development)"
echo "  ✓ nginx /marketplace/api/: added proxy_buffering off"
echo "    proxy_cache off, X-Accel-Buffering no (SSE fix)"
echo "  ✓ marketplace backend restarted (fresh agent load)"
echo ""
echo "  Test chat at: https://edge.etheros.ai/marketplace/"
echo "  Ask the CDL agent: \"What is required for a CDL license?\""
echo ""
