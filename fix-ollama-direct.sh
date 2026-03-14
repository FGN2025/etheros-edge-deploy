#!/usr/bin/env bash
# fix-ollama-direct.sh — Patch both backends to call Ollama directly
# Fixes the 401 auth error by bypassing Open WebUI entirely
set -e

EDGE_DIR="/opt/etheros-edge"
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'

echo ""
echo -e "${YELLOW}══════════════════════════════════════════════════${NC}"
echo -e "${YELLOW}  EtherOS — Patch Backends → Ollama Direct        ${NC}"
echo -e "${YELLOW}══════════════════════════════════════════════════${NC}"
echo ""

# ── Step 1: Test Ollama reachability from backend container ───────────────────
echo -e "${YELLOW}▸${NC} Verifying Ollama reachability..."
docker exec etheros-isp-portal-backend node -e "
fetch('http://ollama:11434/api/tags', {signal: AbortSignal.timeout(5000)})
  .then(r => r.json())
  .then(d => { const names = d.models?.map(m=>m.name) || []; console.log('OLLAMA_OK:' + names.join(',')); })
  .catch(e => { console.log('OLLAMA_FAIL:' + e.message); process.exit(1); })
" && echo -e "  ${GREEN}✓${NC} Ollama reachable from backend container"

# ── Step 2: Rewrite ISP Portal backend ────────────────────────────────────────
echo -e "${YELLOW}▸${NC} Rewriting ISP Portal backend (server.js)..."
cat > "$EDGE_DIR/backends/isp-portal/server.js" << 'JSEOF'
'use strict';
const express = require('express');
const cors = require('cors');
const { randomUUID } = require('crypto');

const app = express();
app.use(express.json());
app.use(cors({ origin: '*' }));

// ── Ollama direct (no auth required) ─────────────────────────────────────────
const OLLAMA_URL = 'http://ollama:11434';
const OPEN_WEBUI_URL = 'http://open-webui:8080';

// ── Edge status (live VPS health + models) ────────────────────────────────────
app.get('/api/edge-status', async (req, res) => {
  try {
    const [healthRes, tagsRes] = await Promise.all([
      fetch(`${OPEN_WEBUI_URL}/health`, { signal: AbortSignal.timeout(8000) }).catch(() => null),
      fetch(`${OLLAMA_URL}/api/tags`,   { signal: AbortSignal.timeout(8000) }).catch(() => null),
    ]);
    const health = healthRes?.ok ? await healthRes.json().catch(() => null) : null;
    const tagsData = tagsRes?.ok ? await tagsRes.json().catch(() => null) : null;
    const models = (tagsData?.models || []).map(m => m.name).filter(Boolean);
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

// ── Edge chat proxy → Ollama direct ──────────────────────────────────────────
app.post('/api/edge-chat', async (req, res) => {
  const { model = 'phi3:mini', messages = [] } = req.body;
  try {
    const upstream = await fetch(`${OLLAMA_URL}/api/chat`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ model, messages, stream: false }),
      signal: AbortSignal.timeout(120000),
    });
    if (!upstream.ok) {
      const err = await upstream.text();
      return res.status(502).json({ error: `Ollama error: ${err}` });
    }
    const data = await upstream.json();
    // Ollama /api/chat response: { message: { role, content } }
    // Normalise to OpenAI-compatible shape so the frontend works unchanged
    const content = data?.message?.content || "Sorry, I couldn't generate a response.";
    res.json({
      choices: [{ message: { role: 'assistant', content } }],
      model,
      _source: 'ollama-direct',
    });
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
app.listen(PORT, '0.0.0.0', () => console.log(`ISP Portal backend running on port ${PORT} [ollama-direct]`));
JSEOF
echo -e "  ${GREEN}✓${NC} ISP Portal backend rewritten"

# ── Step 3: Rewrite Marketplace backend ───────────────────────────────────────
echo -e "${YELLOW}▸${NC} Rewriting Marketplace backend (server.js)..."
cat > "$EDGE_DIR/backends/marketplace/server.js" << 'JSEOF'
'use strict';
const express = require('express');
const cors = require('cors');

const app = express();
app.use(express.json());
app.use(cors({ origin: '*' }));

// ── Ollama direct (no auth required) ─────────────────────────────────────────
const OLLAMA_URL = 'http://ollama:11434';
const OPEN_WEBUI_URL = 'http://open-webui:8080';

// ── Hardcoded agent catalogue (expand as needed) ──────────────────────────────
const AGENTS = [
  { id: 'rural-advisor',    name: 'Rural Community Advisor',  category: 'Community',  model: 'llama3.1:8b', description: 'Expert guidance on rural community development, grants, and resources.' },
  { id: 'tech-support',     name: 'Tech Support Agent',       category: 'Support',    model: 'phi3:mini',   description: 'Friendly first-line technical support for EtherOS users.' },
  { id: 'business-coach',   name: 'Small Business Coach',     category: 'Business',   model: 'llama3.1:8b', description: 'Business planning, marketing, and growth advice for rural entrepreneurs.' },
  { id: 'edu-tutor',        name: 'Education Tutor',          category: 'Education',  model: 'phi3:mini',   description: 'Homework help and learning support for K-12 students.' },
  { id: 'health-navigator', name: 'Health Navigator',         category: 'Health',     model: 'llama3.1:8b', description: 'General health information and telehealth resource navigation.' },
  { id: 'legal-basics',     name: 'Legal Basics Assistant',   category: 'Legal',      model: 'llama3.1:8b', description: 'Plain-English explanations of common legal questions (not legal advice).' },
];

// ── List agents ───────────────────────────────────────────────────────────────
app.get('/api/agents', (req, res) => {
  res.json({ agents: AGENTS, total: AGENTS.length });
});

// ── Get single agent ──────────────────────────────────────────────────────────
app.get('/api/agents/:id', (req, res) => {
  const agent = AGENTS.find(a => a.id === req.params.id);
  if (!agent) return res.status(404).json({ error: 'Agent not found' });
  res.json(agent);
});

// ── List available models ─────────────────────────────────────────────────────
app.get('/api/models', async (req, res) => {
  try {
    const r = await fetch(`${OLLAMA_URL}/api/tags`, { signal: AbortSignal.timeout(8000) });
    const d = await r.json();
    const models = (d.models || []).map(m => m.name);
    res.json({ models });
  } catch (err) {
    res.json({ models: ['phi3:mini', 'llama3.1:8b'], error: String(err) });
  }
});

// ── Agent chat → Ollama direct ────────────────────────────────────────────────
app.post('/api/agents/:id/chat', async (req, res) => {
  const agent = AGENTS.find(a => a.id === req.params.id);
  if (!agent) return res.status(404).json({ error: 'Agent not found' });

  const { messages = [] } = req.body;
  const model = agent.model;

  // Prepend agent system prompt if not already present
  const fullMessages = messages[0]?.role === 'system'
    ? messages
    : [{ role: 'system', content: `You are ${agent.name}. ${agent.description} Be helpful, concise, and friendly.` }, ...messages];

  try {
    const upstream = await fetch(`${OLLAMA_URL}/api/chat`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ model, messages: fullMessages, stream: false }),
      signal: AbortSignal.timeout(120000),
    });
    if (!upstream.ok) {
      const err = await upstream.text();
      return res.status(502).json({ error: `Ollama error: ${err}` });
    }
    const data = await upstream.json();
    // Ollama response: { message: { role, content } }
    const content = data?.message?.content || "I'm currently unavailable. Please try again shortly.";
    res.json({
      reply: content,
      model,
      agentName: agent.name,
      agentId: agent.id,
    });
  } catch (err) {
    res.json({ reply: "I'm currently unavailable. Please try again shortly.", error: true, model });
  }
});

// ── Edge status ───────────────────────────────────────────────────────────────
app.get('/api/edge-status', async (req, res) => {
  try {
    const [healthRes, tagsRes] = await Promise.all([
      fetch(`${OPEN_WEBUI_URL}/health`, { signal: AbortSignal.timeout(8000) }).catch(() => null),
      fetch(`${OLLAMA_URL}/api/tags`,   { signal: AbortSignal.timeout(8000) }).catch(() => null),
    ]);
    const health = healthRes?.ok ? await healthRes.json().catch(() => null) : null;
    const tagsData = tagsRes?.ok ? await tagsRes.json().catch(() => null) : null;
    const models = (tagsData?.models || []).map(m => m.name).filter(Boolean);
    res.json({ edgeOnline: !!health, models, ollamaOnline: models.length > 0, checkedAt: new Date().toISOString() });
  } catch (err) {
    res.json({ edgeOnline: false, models: [], ollamaOnline: false, error: String(err), checkedAt: new Date().toISOString() });
  }
});

// ── Health ────────────────────────────────────────────────────────────────────
app.get('/health', (req, res) => res.json({ status: 'ok', service: 'marketplace-backend', ts: new Date().toISOString() }));

const PORT = process.env.PORT || 3011;
app.listen(PORT, '0.0.0.0', () => console.log(`Marketplace backend running on port ${PORT} [ollama-direct]`));
JSEOF
echo -e "  ${GREEN}✓${NC} Marketplace backend rewritten"

# ── Step 4: Restart both backends ─────────────────────────────────────────────
echo ""
echo -e "${YELLOW}▸${NC} Restarting backend containers..."
cd "$EDGE_DIR"
docker compose restart isp-portal-backend marketplace-backend
sleep 4
echo -e "  ${GREEN}✓${NC} Containers restarted"

# ── Step 5: Verify ────────────────────────────────────────────────────────────
echo ""
echo -e "${YELLOW}▸${NC} Running verification checks..."

# Health checks
ISP_HEALTH=$(curl -sf http://localhost:3010/health | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('status','?'))" 2>/dev/null || echo "FAIL")
MKT_HEALTH=$(curl -sf http://localhost:3011/health | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('status','?'))" 2>/dev/null || echo "FAIL")
echo -e "  ISP Portal health:    ${ISP_HEALTH}"
echo -e "  Marketplace health:   ${MKT_HEALTH}"

# Edge status (tests Ollama connection)
echo -e "${YELLOW}▸${NC} Testing edge-status (Ollama model list)..."
EDGE_STATUS=$(curl -sf http://localhost:3010/api/edge-status | python3 -c "
import json,sys
d=json.load(sys.stdin)
print('ollamaOnline=' + str(d.get('ollamaOnline')))
print('models=' + ','.join(d.get('models',[])))
" 2>/dev/null || echo "FAIL")
echo -e "  $EDGE_STATUS"

# Chat test
echo -e "${YELLOW}▸${NC} Testing live chat (short prompt)..."
CHAT_RESULT=$(curl -sf -X POST http://localhost:3010/api/edge-chat \
  -H "Content-Type: application/json" \
  -d '{"model":"phi3:mini","messages":[{"role":"user","content":"Reply with exactly: CHAT_OK"}]}' \
  | python3 -c "
import json,sys
d=json.load(sys.stdin)
content = d.get('choices',[{}])[0].get('message',{}).get('content','NO_CONTENT')
src = d.get('_source','?')
print(f'content={content[:60]}  source={src}')
" 2>/dev/null || echo "CHAT_FAIL")
echo -e "  $CHAT_RESULT"

# Marketplace agents test
echo -e "${YELLOW}▸${NC} Testing marketplace agents list..."
MKT_AGENTS=$(curl -sf http://localhost:3011/api/agents | python3 -c "
import json,sys
d=json.load(sys.stdin)
total=d.get('total',0)
names=[a['name'] for a in d.get('agents',[])]
print(f'{total} agents: ' + ', '.join(names[:3]) + ('...' if total>3 else ''))
" 2>/dev/null || echo "FAIL")
echo -e "  $MKT_AGENTS"

echo ""
echo -e "${GREEN}══════════════════════════════════════════════════${NC}"
echo -e "${GREEN}  Patch complete — both backends on Ollama direct  ${NC}"
echo -e "${GREEN}══════════════════════════════════════════════════${NC}"
echo ""
echo "Next: test live chat at https://edge.etheros.ai/isp-portal/"
echo "      and agent chat at https://edge.etheros.ai/marketplace/"
echo ""
