#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════════
# EtherOS — Deploy 3C + 3D Node Backends on VPS
# Adds ISP Portal and Agent Marketplace as Docker services on edge.etheros.ai
#
# Run on VPS: bash deploy-backends.sh
# ═══════════════════════════════════════════════════════════════════════════════
set -euo pipefail

GREEN='\033[0;32m'; CYAN='\033[0;36m'; YELLOW='\033[1;33m'; BOLD='\033[1m'; RED='\033[0;31m'; NC='\033[0m'
EDGE_DIR="/opt/etheros-edge"
DOMAIN="edge.etheros.ai"

echo -e "${CYAN}${BOLD}━━━ EtherOS — Deploy 3C + 3D Backends ━━━${NC}"
echo ""

# ── Install Node.js 20 if not present ────────────────────────────────────────
if ! command -v node &>/dev/null || [[ $(node --version | cut -d. -f1 | tr -d 'v') -lt 18 ]]; then
  echo -e "${YELLOW}▸${NC} Installing Node.js 20..."
  curl -fsSL https://deb.nodesource.com/setup_20.x | bash - > /dev/null 2>&1
  apt-get install -y -qq nodejs > /dev/null 2>&1
  echo -e "  ${GREEN}✓${NC} Node.js $(node --version)"
else
  echo -e "  ${GREEN}✓${NC} Node.js $(node --version) already installed"
fi

# ── Create app directories ────────────────────────────────────────────────────
echo -e "${YELLOW}▸${NC} Creating backend directories..."
mkdir -p "$EDGE_DIR/backends/isp-portal"
mkdir -p "$EDGE_DIR/backends/marketplace"
echo -e "  ${GREEN}✓${NC} Directories created"

# ── Write ISP Portal backend (server only — no Vite, pure Express) ────────────
echo -e "${YELLOW}▸${NC} Writing ISP Portal backend..."

# package.json
cat > "$EDGE_DIR/backends/isp-portal/package.json" << 'PKG'
{
  "name": "etheros-isp-portal-backend",
  "version": "1.0.0",
  "type": "commonjs",
  "scripts": { "start": "node server.js" },
  "dependencies": {
    "express": "^4.18.2",
    "cors": "^2.8.5"
  }
}
PKG

# server.js
cat > "$EDGE_DIR/backends/isp-portal/server.js" << 'JSEOF'
'use strict';
const express = require('express');
const cors = require('cors');
const { randomUUID } = require('crypto');

const app = express();
app.use(express.json());
app.use(cors({ origin: '*' }));

const EDGE_API = 'https://edge.etheros.ai/api';

// ── Edge status (live VPS health + models) ────────────────────────────────────
app.get('/api/edge-status', async (req, res) => {
  try {
    const [healthRes, modelsRes] = await Promise.all([
      fetch(`${EDGE_API}/health`, { signal: AbortSignal.timeout(8000) }).catch(() => null),
      fetch(`${EDGE_API}/models`,  { signal: AbortSignal.timeout(8000) }).catch(() => null),
    ]);
    const health = healthRes?.ok ? await healthRes.json().catch(() => null) : null;
    const modelsData = modelsRes?.ok ? await modelsRes.json().catch(() => null) : null;
    const models = (modelsData?.data || []).map(m => m.id || m.name).filter(Boolean);
    res.json({
      edgeOnline: !!health,
      health,
      models,
      ollamaOnline: models.length > 0,
      checkedAt: new Date().toISOString(),
      edgeUrl: 'https://edge.etheros.ai',
    });
  } catch (err) {
    res.json({ edgeOnline: false, models: [], ollamaOnline: false, error: String(err), checkedAt: new Date().toISOString() });
  }
});

// ── Edge chat proxy (streams Ollama completions) ──────────────────────────────
app.post('/api/edge-chat', async (req, res) => {
  const { model = 'phi3:mini', messages = [] } = req.body;
  try {
    const upstream = await fetch(`${EDGE_API}/chat/completions`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ model, messages, stream: false }),
      signal: AbortSignal.timeout(60000),
    });
    if (!upstream.ok) {
      const err = await upstream.text();
      return res.status(502).json({ error: `Upstream error: ${err}` });
    }
    const data = await upstream.json();
    res.json(data);
  } catch (err) {
    res.status(502).json({ error: String(err) });
  }
});

// ── ISP tenant config (reads from /opt/etheros-edge/isp-config/) ─────────────
app.get('/api/isp-config', (req, res) => {
  const fs = require('fs');
  const path = require('path');
  const configDir = '/opt/etheros-edge/isp-config';
  try {
    const files = fs.readdirSync(configDir).filter(f => f.endsWith('.json'));
    const configs = files.map(f => {
      try { return JSON.parse(fs.readFileSync(path.join(configDir, f), 'utf8')); }
      catch { return null; }
    }).filter(Boolean);
    res.json(configs);
  } catch {
    res.json([{ slug: 'etheros-default', name: 'EtherOS AI', domain: 'edge.etheros.ai', accent_color: '#00C2CB' }]);
  }
});

// ── Health ────────────────────────────────────────────────────────────────────
app.get('/health', (req, res) => res.json({ status: 'ok', service: 'isp-portal-backend', ts: new Date().toISOString() }));

const PORT = process.env.PORT || 3010;
app.listen(PORT, '0.0.0.0', () => console.log(`ISP Portal backend running on port ${PORT}`));
JSEOF

echo -e "  ${GREEN}✓${NC} ISP Portal backend written"

# ── Write Marketplace backend ─────────────────────────────────────────────────
echo -e "${YELLOW}▸${NC} Writing Marketplace backend..."

cat > "$EDGE_DIR/backends/marketplace/package.json" << 'PKG'
{
  "name": "etheros-marketplace-backend",
  "version": "1.0.0",
  "type": "commonjs",
  "scripts": { "start": "node server.js" },
  "dependencies": {
    "express": "^4.18.2",
    "cors": "^2.8.5"
  }
}
PKG

cat > "$EDGE_DIR/backends/marketplace/server.js" << 'JSEOF'
'use strict';
const express = require('express');
const cors = require('cors');

const app = express();
app.use(express.json());
app.use(cors({ origin: '*' }));

const EDGE_API = 'https://edge.etheros.ai/api';

// Agent catalog (seeded from Sprint 3D data)
const AGENTS = [
  { id: 'agent-1', name: 'CDL Tutor', slug: 'cdl-tutor', category: 'Learning', modelId: 'llama3.1:8b', systemPrompt: "You are a CDL exam tutor. Help students prepare for their commercial driver's license exams with practice questions, traffic laws, and pre-trip inspection procedures.", pricingType: 'addon', priceMonthly: 4.99, isEnabled: true, rating: 4.6, reviewCount: 23 },
  { id: 'agent-2', name: 'FarmBot', slug: 'farmbot', category: 'Agriculture', modelId: 'llama3.1:8b', systemPrompt: 'You are an agricultural advisor. Help farmers with crop rotation, pest management, soil health, weather predictions, and livestock care.', pricingType: 'free', priceMonthly: 0, isEnabled: true, rating: 4.8, reviewCount: 31 },
  { id: 'agent-3', name: 'HomeHelper', slug: 'homehelper', category: 'Business', modelId: 'mistral:7b', systemPrompt: 'You are a home maintenance expert. Provide clear, safe guidance for common home repair tasks including plumbing, basic electrical, painting, and seasonal maintenance.', pricingType: 'addon', priceMonthly: 2.99, isEnabled: true, rating: 4.3, reviewCount: 12 },
  { id: 'agent-4', name: 'ValleyBot', slug: 'valleybot', category: 'Local', modelId: 'phi3:mini', systemPrompt: "You are ValleyBot, the community assistant for Valley Fiber subscribers. Help with local business lookups, community events, and fiber internet service questions.", pricingType: 'free', priceMonthly: 0, isEnabled: true, rating: 4.5, reviewCount: 18 },
  { id: 'agent-5', name: 'LocalNews', slug: 'localnews', category: 'Local', modelId: 'phi3:mini', systemPrompt: 'You are a local news curator. Provide summaries of community news, weather forecasts, school updates, and local government announcements.', pricingType: 'free', priceMonthly: 0, isEnabled: true, rating: 4.4, reviewCount: 15 },
  { id: 'agent-6', name: 'BusinessAssist', slug: 'business-assist', category: 'Business', modelId: 'llama3.1:8b', systemPrompt: 'You are a small business assistant. Help with invoicing, basic bookkeeping, inventory management, and professional customer communication.', pricingType: 'addon', priceMonthly: 4.99, isEnabled: true, rating: 4.2, reviewCount: 7 },
  { id: 'agent-7', name: 'MathTutor', slug: 'math-tutor', category: 'Learning', modelId: 'llama3.1:8b', systemPrompt: 'You are a patient math tutor. Explain concepts clearly, provide step-by-step solutions, generate practice problems, and adapt to the student\'s level.', pricingType: 'addon', priceMonthly: 2.99, isEnabled: true, rating: 4.6, reviewCount: 20 },
  { id: 'agent-8', name: 'TruckLogPro', slug: 'trucklogpro', category: 'Business', modelId: 'llama3.1:8b', systemPrompt: 'You are a trucking logistics professional. Help with route planning, Hours of Service compliance, fuel cost optimization, and load board strategies.', pricingType: 'addon', priceMonthly: 7.99, isEnabled: true, rating: 4.7, reviewCount: 9 },
];

// ── Models list (live from VPS) ───────────────────────────────────────────────
app.get('/api/models', async (req, res) => {
  try {
    const r = await fetch(`${EDGE_API}/models`, { signal: AbortSignal.timeout(8000) });
    if (!r.ok) throw new Error(`HTTP ${r.status}`);
    const data = await r.json();
    const models = (data.data || []).map(m => ({ id: m.id, name: m.name || m.id }));
    res.json({ models, online: true });
  } catch {
    res.json({ models: [{ id: 'phi3:mini', name: 'Phi-3 Mini' }, { id: 'llama3.1:8b', name: 'Llama 3.1 8B' }], online: false });
  }
});

// ── Agents catalog ────────────────────────────────────────────────────────────
app.get('/api/agents', (req, res) => res.json(AGENTS));
app.get('/api/agents/:id', (req, res) => {
  const agent = AGENTS.find(a => a.id === req.params.id || a.slug === req.params.id);
  agent ? res.json(agent) : res.status(404).json({ error: 'Not found' });
});

// ── Live chat (real Ollama completions) ───────────────────────────────────────
app.post('/api/chat', async (req, res) => {
  const { agentId, message, history = [] } = req.body;
  if (!agentId || !message) return res.status(400).json({ error: 'agentId and message required' });

  const agent = AGENTS.find(a => a.id === agentId || a.slug === agentId);
  if (!agent) return res.status(404).json({ error: 'Agent not found' });

  // Determine best available model — fall back to phi3:mini if agent model not loaded
  let model = agent.modelId;
  try {
    const r = await fetch(`${EDGE_API}/models`, { signal: AbortSignal.timeout(5000) });
    if (r.ok) {
      const data = await r.json();
      const available = (data.data || []).map(m => m.id);
      if (!available.includes(model)) {
        console.log(`Model ${model} not available, falling back to phi3:mini`);
        model = available.includes('phi3:mini') ? 'phi3:mini' : (available[0] || 'phi3:mini');
      }
    }
  } catch { model = 'phi3:mini'; }

  const messages = [
    { role: 'system', content: agent.systemPrompt },
    ...history.slice(-10), // last 10 turns for context
    { role: 'user', content: message },
  ];

  try {
    const upstream = await fetch(`${EDGE_API}/chat/completions`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ model, messages, stream: false }),
      signal: AbortSignal.timeout(90000),
    });
    if (!upstream.ok) {
      const err = await upstream.text();
      return res.status(502).json({ reply: "I'm having trouble connecting right now. Please try again shortly.", error: true });
    }
    const data = await upstream.json();
    const reply = data?.choices?.[0]?.message?.content || "Sorry, I couldn't generate a response.";
    res.json({ reply, model, agentName: agent.name, agentId: agent.id });
  } catch (err) {
    res.json({ reply: "I'm currently unavailable. Please try again shortly.", error: true, model });
  }
});

// ── Health ────────────────────────────────────────────────────────────────────
app.get('/health', (req, res) => res.json({ status: 'ok', service: 'marketplace-backend', ts: new Date().toISOString() }));

const PORT = process.env.PORT || 3011;
app.listen(PORT, '0.0.0.0', () => console.log(`Marketplace backend running on port ${PORT}`));
JSEOF

echo -e "  ${GREEN}✓${NC} Marketplace backend written"

# ── Install npm dependencies ──────────────────────────────────────────────────
echo -e "${YELLOW}▸${NC} Installing npm dependencies..."
cd "$EDGE_DIR/backends/isp-portal" && npm install --silent
cd "$EDGE_DIR/backends/marketplace" && npm install --silent
echo -e "  ${GREEN}✓${NC} Dependencies installed"

# ── Patch docker-compose.yml to add backend services ─────────────────────────
echo -e "${YELLOW}▸${NC} Patching docker-compose.yml to add backend services..."
python3 << 'PYEOF'
import yaml, shutil
from pathlib import Path

compose_path = Path('/opt/etheros-edge/docker-compose.yml')
shutil.copy2(compose_path, compose_path.with_suffix('.yml.pre-backends'))

data = yaml.safe_load(compose_path.read_text())
services = data.setdefault('services', {})

# Add ISP Portal backend service
services['isp-portal-backend'] = {
    'image': 'node:20-alpine',
    'container_name': 'etheros-isp-portal-backend',
    'restart': 'unless-stopped',
    'working_dir': '/app',
    'volumes': ['/opt/etheros-edge/backends/isp-portal:/app'],
    'networks': ['etheros-net'],
    'ports': ['127.0.0.1:3010:3010'],
    'environment': ['PORT=3010', 'NODE_ENV=production'],
    'command': 'node server.js',
}

# Add Marketplace backend service
services['marketplace-backend'] = {
    'image': 'node:20-alpine',
    'container_name': 'etheros-marketplace-backend',
    'restart': 'unless-stopped',
    'working_dir': '/app',
    'volumes': ['/opt/etheros-edge/backends/marketplace:/app'],
    'networks': ['etheros-net'],
    'ports': ['127.0.0.1:3011:3011'],
    'environment': ['PORT=3011', 'NODE_ENV=production'],
    'command': 'node server.js',
}

compose_path.write_text(yaml.dump(data, default_flow_style=False, sort_keys=False))
print('docker-compose.yml patched successfully')
PYEOF
echo -e "  ${GREEN}✓${NC} docker-compose.yml updated"

# ── Patch nginx to proxy /isp-portal/api/ and /marketplace/api/ ───────────────
echo -e "${YELLOW}▸${NC} Patching nginx config to proxy backend API routes..."
NGINX_CONF="$EDGE_DIR/nginx/conf.d/etheros-edge.conf"

# Insert backend proxy locations before the closing of the HTTPS server block
python3 << PYEOF
content = open('$NGINX_CONF').read()

backend_locations = """
    # ISP Portal backend API
    location /isp-portal/api/ {
        rewrite ^/isp-portal/api/(.*) /api/\$1 break;
        proxy_pass         http://etheros-isp-portal-backend:3010;
        proxy_set_header   Host \$host;
        proxy_set_header   X-Real-IP \$remote_addr;
        proxy_set_header   X-Forwarded-Proto \$scheme;
    }

    # Marketplace backend API
    location /marketplace/api/ {
        rewrite ^/marketplace/api/(.*) /api/\$1 break;
        proxy_pass         http://etheros-marketplace-backend:3011;
        proxy_set_header   Host \$host;
        proxy_set_header   X-Real-IP \$remote_addr;
        proxy_set_header   X-Forwarded-Proto \$scheme;
    }

    # Backend health checks
    location /isp-portal/health {
        proxy_pass http://etheros-isp-portal-backend:3010/health;
    }
    location /marketplace/health {
        proxy_pass http://etheros-marketplace-backend:3011/health;
    }
"""

# Insert before the last closing brace of the HTTPS server block
# Find the location /health block and insert after it
insert_before = '    location /health {'
if insert_before in content and '/isp-portal/api/' not in content:
    content = content.replace(insert_before, backend_locations + '\n' + insert_before)
    open('$NGINX_CONF', 'w').write(content)
    print('nginx config patched')
else:
    print('nginx already patched or marker not found — skipping')
PYEOF
echo -e "  ${GREEN}✓${NC} nginx config updated"

# ── Start the new services ────────────────────────────────────────────────────
echo ""
echo -e "${YELLOW}▸${NC} Starting backend services..."
cd "$EDGE_DIR"
docker compose up -d --no-deps isp-portal-backend marketplace-backend
sleep 5

# Reload nginx to pick up new proxy routes
docker exec etheros-nginx nginx -s reload 2>/dev/null || \
  docker compose restart nginx
echo -e "  ${GREEN}✓${NC} Services started, nginx reloaded"

# ── Health check ──────────────────────────────────────────────────────────────
echo ""
echo -e "${YELLOW}▸${NC} Running health checks..."
sleep 3

ISP_HEALTH=$(curl -sf http://localhost:3010/health 2>/dev/null | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('status','?'))" 2>/dev/null || echo "unreachable")
MKT_HEALTH=$(curl -sf http://localhost:3011/health 2>/dev/null | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('status','?'))" 2>/dev/null || echo "unreachable")
EDGE_STATUS=$(curl -sf http://localhost:3010/api/edge-status 2>/dev/null | python3 -c "import json,sys; d=json.load(sys.stdin); print('online' if d.get('edgeOnline') else 'offline')" 2>/dev/null || echo "unknown")

echo ""
echo -e "${GREEN}${BOLD}━━━ Backend Deploy Complete ━━━${NC}"
echo ""
echo -e "  ISP Portal backend:    ${ISP_HEALTH}"
echo -e "  Marketplace backend:   ${MKT_HEALTH}"
echo -e "  Edge.etheros.ai:       ${EDGE_STATUS}"
echo ""
echo -e "${BOLD}  Live endpoints:${NC}"
echo -e "  ${CYAN}https://edge.etheros.ai/isp-portal/api/edge-status${NC}"
echo -e "  ${CYAN}https://edge.etheros.ai/marketplace/api/models${NC}"
echo -e "  ${CYAN}https://edge.etheros.ai/marketplace/api/chat${NC}  (POST)"
echo ""
echo -e "${BOLD}  Container status:${NC}"
docker compose -f "$EDGE_DIR/docker-compose.yml" ps --format "table {{.Name}}\t{{.Status}}" 2>/dev/null || docker compose -f "$EDGE_DIR/docker-compose.yml" ps
echo ""
