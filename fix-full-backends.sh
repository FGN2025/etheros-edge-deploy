#!/usr/bin/env bash
# fix-full-backends.sh — Complete rewrite of both Docker backends with full data layer
# ISP Portal: dashboard, terminals, subscribers, agents, revenue, settings, edge-status, edge-chat
# Marketplace: agents (CRUD), activations, reviews, isp-tenants, models, chat, edge-status
set -e

EDGE_DIR="/opt/etheros-edge"
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'

echo ""
echo -e "${YELLOW}══════════════════════════════════════════════════${NC}"
echo -e "${YELLOW}  EtherOS — Full Backend Rewrite (Data Layer)     ${NC}"
echo -e "${YELLOW}══════════════════════════════════════════════════${NC}"
echo ""

# ══════════════════════════════════════════════════════════════════════════════
# ISP PORTAL BACKEND (port 3010)
# ══════════════════════════════════════════════════════════════════════════════
echo -e "${YELLOW}▸${NC} Writing ISP Portal backend..."
cat > "$EDGE_DIR/backends/isp-portal/server.js" << 'JSEOF'
'use strict';
const express = require('express');
const cors = require('cors');
const { randomUUID } = require('crypto');

const app = express();
app.use(express.json());
app.use(cors({ origin: '*' }));

const OLLAMA_URL = 'http://ollama:11434';
const OPEN_WEBUI_URL = 'http://open-webui:8080';

// ── In-memory data store ──────────────────────────────────────────────────────
const db = {
  terminals: [
    { id: 't-001', name: 'Terminal AZ-001', location: 'Cave Creek Library', status: 'online',  model: 'EtherOS v1', lastSeen: new Date(Date.now()-120000).toISOString(),  ip: '10.1.0.101', subscriberId: 'sub-1' },
    { id: 't-002', name: 'Terminal AZ-002', location: 'Carefree Community Center', status: 'online',  model: 'EtherOS v1', lastSeen: new Date(Date.now()-300000).toISOString(),  ip: '10.1.0.102', subscriberId: 'sub-2' },
    { id: 't-003', name: 'Terminal AZ-003', location: 'Cave Creek Town Hall',  status: 'offline', model: 'EtherOS v1', lastSeen: new Date(Date.now()-86400000).toISOString(), ip: '10.1.0.103', subscriberId: null },
    { id: 't-004', name: 'Terminal NM-001', location: 'Taos Public Library',   status: 'online',  model: 'EtherOS v1', lastSeen: new Date(Date.now()-60000).toISOString(),   ip: '10.2.0.101', subscriberId: 'sub-3' },
    { id: 't-005', name: 'Terminal NM-002', location: 'Santa Fe Senior Center', status: 'provisioning', model: 'EtherOS v1', lastSeen: new Date(Date.now()-900000).toISOString(),  ip: '10.2.0.102', subscriberId: null },
    { id: 't-006', name: 'Terminal MT-001', location: 'Billings Community Hub', status: 'online',  model: 'EtherOS v1', lastSeen: new Date(Date.now()-180000).toISOString(), ip: '10.3.0.101', subscriberId: 'sub-4' },
  ],
  subscribers: [
    { id: 'sub-1', name: 'Maria Garcia',      email: 'mgarcia@example.com',   plan: 'Premium', status: 'active',   agentsActive: 5, monthlySpend: 15.96, joinDate: '2025-09-01', terminalId: 't-001' },
    { id: 'sub-2', name: 'James Wilson',       email: 'jwilson@example.com',   plan: 'Basic',   status: 'active',   agentsActive: 2, monthlySpend: 0,     joinDate: '2025-10-12', terminalId: 't-002' },
    { id: 'sub-3', name: 'Sarah Chen',         email: 'schen@example.com',     plan: 'Premium', status: 'active',   agentsActive: 3, monthlySpend: 7.98,  joinDate: '2025-11-03', terminalId: 't-004' },
    { id: 'sub-4', name: 'Mike Johnson',       email: 'mjohnson@example.com',  plan: 'Basic',   status: 'active',   agentsActive: 1, monthlySpend: 2.99,  joinDate: '2025-12-15', terminalId: 't-006' },
    { id: 'sub-5', name: 'Emily Rodriguez',    email: 'erodriguez@example.com', plan: 'Premium', status: 'active',   agentsActive: 2, monthlySpend: 4.99,  joinDate: '2026-01-07', terminalId: null },
    { id: 'sub-6', name: 'David Kim',          email: 'dkim@example.com',      plan: 'Basic',   status: 'inactive', agentsActive: 1, monthlySpend: 0,     joinDate: '2026-01-20', terminalId: null },
  ],
  agents: [
    { id: 'agent-1', name: 'Rural Advisor',     category: 'Community', model: 'llama3.1:8b', status: 'LIVE', isEnabled: true, createdAt: '2026-01-01' },
    { id: 'agent-2', name: 'Tech Support',       category: 'Support',   model: 'phi3:mini',   status: 'LIVE', isEnabled: true, createdAt: '2026-01-15' },
    { id: 'agent-3', name: 'Business Coach',     category: 'Business',  model: 'llama3.1:8b', status: 'LIVE', isEnabled: true, createdAt: '2026-02-01' },
    { id: 'agent-4', name: 'Education Tutor',    category: 'Education', model: 'phi3:mini',   status: 'LIVE', isEnabled: true, createdAt: '2026-02-10' },
    { id: 'agent-5', name: 'Health Navigator',   category: 'Health',    model: 'llama3.1:8b', status: 'REVIEW', isEnabled: false, createdAt: '2026-03-01' },
  ],
  revenue: [
    { month: 'Oct 2025', ispShare: 1200, totalRevenue: 2400 },
    { month: 'Nov 2025', ispShare: 1850, totalRevenue: 3700 },
    { month: 'Dec 2025', ispShare: 2100, totalRevenue: 4200 },
    { month: 'Jan 2026', ispShare: 2640, totalRevenue: 5280 },
    { month: 'Feb 2026', ispShare: 3120, totalRevenue: 6240 },
    { month: 'Mar 2026', ispShare: 3580, totalRevenue: 7160 },
  ],
  activity: [
    { id: 'a-1', type: 'terminal',    message: 'Terminal AZ-001 came online',             timestamp: new Date(Date.now()-180000).toISOString() },
    { id: 'a-2', type: 'subscriber',  message: 'New subscriber: Emily Rodriguez (Premium)', timestamp: new Date(Date.now()-3600000).toISOString() },
    { id: 'a-3', type: 'agent',       message: 'Agent "Rural Advisor" enabled by admin',   timestamp: new Date(Date.now()-7200000).toISOString() },
    { id: 'a-4', type: 'terminal',    message: 'Terminal AZ-003 went offline',             timestamp: new Date(Date.now()-86400000).toISOString() },
    { id: 'a-5', type: 'subscriber',  message: 'Subscriber David Kim downgraded to Basic', timestamp: new Date(Date.now()-172800000).toISOString() },
  ],
  settings: {
    ispName: 'EtherOS AI',
    domain: 'edge.etheros.ai',
    accentColor: '#00C2CB',
    supportEmail: 'admin@etheros.ai',
    gpnEnabled: false,
    gpnNode: '',
    basicPlanPrice: 0,
    premiumPlanPrice: 14.99,
  },
};

// ── Helpers ────────────────────────────────────────────────────────────────────
async function getEdgeStatus() {
  try {
    const [healthRes, tagsRes] = await Promise.all([
      fetch(`${OPEN_WEBUI_URL}/health`, { signal: AbortSignal.timeout(8000) }).catch(() => null),
      fetch(`${OLLAMA_URL}/api/tags`,   { signal: AbortSignal.timeout(8000) }).catch(() => null),
    ]);
    const health = healthRes?.ok ? await healthRes.json().catch(() => null) : null;
    const tagsData = tagsRes?.ok ? await tagsRes.json().catch(() => null) : null;
    const models = (tagsData?.models || []).map(m => m.name).filter(Boolean);
    return { health, models, ollamaOnline: models.length > 0, edgeOnline: !!health, edgeUrl: 'https://edge.etheros.ai', checkedAt: new Date().toISOString() };
  } catch (err) {
    return { health: null, models: [], ollamaOnline: false, edgeOnline: false, error: String(err), checkedAt: new Date().toISOString() };
  }
}

// ── Routes ────────────────────────────────────────────────────────────────────

// Dashboard
app.get('/api/dashboard', async (req, res) => {
  const edge = await getEdgeStatus();
  const online = db.terminals.filter(t => t.status === 'online').length;
  const offline = db.terminals.filter(t => t.status === 'offline').length;
  const provisioning = db.terminals.filter(t => t.status === 'provisioning').length;
  const activeSubs = db.subscribers.filter(s => s.status === 'active').length;
  const totalSpend = db.subscribers.reduce((s, sub) => s + sub.monthlySpend, 0);
  const latestRev = db.revenue[db.revenue.length - 1];
  const prevRev = db.revenue[db.revenue.length - 2];
  res.json({
    totalTerminals: db.terminals.length,
    online, offline, provisioning,
    activeSubscribers: activeSubs,
    monthlyRevenue: latestRev?.ispShare || 0,
    prevMonthlyRevenue: prevRev?.ispShare || 0,
    arpu: activeSubs > 0 ? Math.round((totalSpend / activeSubs) * 100) / 100 : 0,
    revenueByMonth: db.revenue.slice(-6),
    activity: db.activity.slice(0, 5),
    liveModels: edge.models,
    edgeOnline: edge.ollamaOnline,
    edgeUrl: 'https://edge.etheros.ai',
  });
});

// Edge status
app.get('/api/edge-status', async (req, res) => { res.json(await getEdgeStatus()); });

// Edge chat (ISP Portal quick chat)
app.post('/api/edge-chat', async (req, res) => {
  const { model = 'phi3:mini', messages = [] } = req.body;
  try {
    const upstream = await fetch(`${OLLAMA_URL}/api/chat`, {
      method: 'POST', headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ model, messages, stream: false }),
      signal: AbortSignal.timeout(120000),
    });
    if (!upstream.ok) return res.status(502).json({ error: await upstream.text() });
    const data = await upstream.json();
    const content = data?.message?.content || "Sorry, I couldn't generate a response.";
    res.json({ choices: [{ message: { role: 'assistant', content } }], model, _source: 'ollama-direct' });
  } catch (err) { res.status(502).json({ error: String(err) }); }
});

// Terminals
app.get('/api/terminals', (req, res) => res.json(db.terminals));
app.get('/api/terminals/:id', (req, res) => {
  const t = db.terminals.find(x => x.id === req.params.id);
  t ? res.json(t) : res.status(404).json({ error: 'Not found' });
});

// Subscribers
app.get('/api/subscribers', (req, res) => res.json(db.subscribers));
app.get('/api/subscribers/:id', (req, res) => {
  const s = db.subscribers.find(x => x.id === req.params.id);
  s ? res.json(s) : res.status(404).json({ error: 'Not found' });
});
app.post('/api/subscribers', (req, res) => {
  const sub = { id: 'sub-' + randomUUID().slice(0,8), ...req.body, createdAt: new Date().toISOString() };
  db.subscribers.push(sub);
  res.status(201).json(sub);
});

// Agents (ISP view — toggle on/off)
app.get('/api/agents', (req, res) => res.json(db.agents));
app.post('/api/agents', (req, res) => {
  const agent = { id: 'agent-' + randomUUID().slice(0,8), ...req.body, createdAt: new Date().toISOString() };
  db.agents.push(agent);
  res.status(201).json(agent);
});
app.patch('/api/agents/:id/toggle', (req, res) => {
  const agent = db.agents.find(a => a.id === req.params.id);
  if (!agent) return res.status(404).json({ error: 'Not found' });
  agent.isEnabled = req.body.enabled !== undefined ? req.body.enabled : !agent.isEnabled;
  res.json(agent);
});

// Revenue
app.get('/api/revenue', (req, res) => res.json(db.revenue));

// Activity
app.get('/api/activity', (req, res) => res.json(db.activity));

// ISP Config
app.get('/api/isp-config', (req, res) => {
  const fs = require('fs'), path = require('path');
  const configDir = '/opt/etheros-edge/isp-config';
  try {
    const files = fs.readdirSync(configDir).filter(f => f.endsWith('.json'));
    const configs = files.map(f => { try { return JSON.parse(fs.readFileSync(path.join(configDir, f), 'utf8')); } catch { return null; } }).filter(Boolean);
    res.json(configs);
  } catch { res.json([{ slug: 'etheros-default', name: 'EtherOS AI', domain: 'edge.etheros.ai', accent_color: '#00C2CB' }]); }
});

// Settings
app.get('/api/settings', (req, res) => res.json(db.settings));
app.patch('/api/settings', (req, res) => {
  Object.assign(db.settings, req.body);
  res.json(db.settings);
});

// Health
app.get('/health', (req, res) => res.json({ status: 'ok', service: 'isp-portal-backend', ts: new Date().toISOString() }));

const PORT = process.env.PORT || 3010;
app.listen(PORT, '0.0.0.0', () => console.log(`ISP Portal backend running on port ${PORT} [full-data-layer]`));
JSEOF
echo -e "  ${GREEN}✓${NC} ISP Portal backend written"

# ══════════════════════════════════════════════════════════════════════════════
# MARKETPLACE BACKEND (port 3011)
# ══════════════════════════════════════════════════════════════════════════════
echo -e "${YELLOW}▸${NC} Writing Marketplace backend..."
cat > "$EDGE_DIR/backends/marketplace/server.js" << 'JSEOF'
'use strict';
const express = require('express');
const cors = require('cors');
const { randomUUID } = require('crypto');

const app = express();
app.use(express.json());
app.use(cors({ origin: '*' }));

const OLLAMA_URL = 'http://ollama:11434';
const OPEN_WEBUI_URL = 'http://open-webui:8080';

// ── In-memory data store ──────────────────────────────────────────────────────
const db = {
  agents: [
    { id: 'rural-advisor',    slug: 'rural-advisor',    name: 'Rural Community Advisor', category: 'Community',  modelId: 'llama3.1:8b', status: 'LIVE', isEnabled: true, creatorRole: 'etheros', price: 0,    description: 'Expert guidance on rural community development, grants, and resources.', systemPrompt: 'You are a Rural Community Advisor specializing in rural development, grants, and community resources across America. Be helpful, practical, and focused on rural contexts.', rating: 4.8, reviewCount: 124, activations: 312 },
    { id: 'tech-support',     slug: 'tech-support',     name: 'Tech Support Agent',      category: 'Support',    modelId: 'phi3:mini',   status: 'LIVE', isEnabled: true, creatorRole: 'etheros', price: 0,    description: 'Friendly first-line technical support for EtherOS terminals and connected devices.', systemPrompt: 'You are a friendly tech support agent for EtherOS. Help users with their terminals, internet connection, and software issues. Be patient and explain things clearly.', rating: 4.6, reviewCount: 89, activations: 198 },
    { id: 'business-coach',   slug: 'business-coach',   name: 'Small Business Coach',    category: 'Business',   modelId: 'llama3.1:8b', status: 'LIVE', isEnabled: true, creatorRole: 'isp',     price: 2.99, description: 'Business planning, marketing, and growth advice for rural entrepreneurs.', systemPrompt: 'You are a small business coach specializing in rural entrepreneurship. Provide practical advice on business planning, marketing on a budget, and accessing rural business grants.', rating: 4.9, reviewCount: 67, activations: 156 },
    { id: 'edu-tutor',        slug: 'edu-tutor',        name: 'Education Tutor',         category: 'Learning',   modelId: 'phi3:mini',   status: 'LIVE', isEnabled: true, creatorRole: 'etheros', price: 0,    description: 'Homework help and learning support for K-12 students and adult learners.', systemPrompt: 'You are a patient and encouraging education tutor for K-12 students. Explain concepts clearly, use examples, and adapt to the student\'s level. Make learning fun.', rating: 4.7, reviewCount: 203, activations: 445 },
    { id: 'health-navigator', slug: 'health-navigator', name: 'Health Navigator',        category: 'Health',     modelId: 'llama3.1:8b', status: 'LIVE', isEnabled: true, creatorRole: 'isp',     price: 1.99, description: 'General health information and telehealth resource navigation for rural communities.', systemPrompt: 'You are a health navigator helping rural residents access healthcare resources. Provide general health information, help find local services, and explain telehealth options. Always recommend professional medical consultation for medical decisions.', rating: 4.5, reviewCount: 45, activations: 98 },
    { id: 'legal-basics',     slug: 'legal-basics',     name: 'Legal Basics Assistant',  category: 'Community',  modelId: 'llama3.1:8b', status: 'REVIEW', isEnabled: false, creatorRole: 'third_party', price: 4.99, description: 'Plain-English explanations of common legal questions. Not legal advice.', systemPrompt: 'You are a legal information assistant. Explain legal concepts and procedures in plain English. Always clarify you are not providing legal advice and recommend consulting a licensed attorney for specific situations.', rating: 4.3, reviewCount: 12, activations: 23 },
    { id: 'ag-advisor',       slug: 'ag-advisor',       name: 'Agriculture Advisor',     category: 'Agriculture', modelId: 'llama3.1:8b', status: 'LIVE', isEnabled: true, creatorRole: 'etheros', price: 0, description: 'Crop management, soil health, irrigation, and USDA program guidance for farmers.', systemPrompt: 'You are an agriculture advisor helping rural farmers with crop management, soil health, irrigation, and accessing USDA programs. Provide practical, science-based guidance.', rating: 4.9, reviewCount: 78, activations: 187 },
  ],
  ispTenants: [
    { id: 'isp-1', name: 'Valley Fiber Co.',     slug: 'valley-fiber',   state: 'AZ', subscriberCount: 312, agentCount: 5,  monthlyRevenue: 2840, status: 'active' },
    { id: 'isp-2', name: 'Mesa Broadband',       slug: 'mesa-broadband', state: 'NM', subscriberCount: 198, agentCount: 4,  monthlyRevenue: 1720, status: 'active' },
    { id: 'isp-3', name: 'Big Sky Connect',      slug: 'bigsky-connect', state: 'MT', subscriberCount: 156, agentCount: 3,  monthlyRevenue: 1380, status: 'active' },
    { id: 'isp-4', name: 'Prairie Net',          slug: 'prairie-net',    state: 'WY', subscriberCount: 134, agentCount: 4,  monthlyRevenue: 1150, status: 'active' },
    { id: 'isp-5', name: 'Snake River Wireless', slug: 'snake-river',    state: 'ID', subscriberCount: 121, agentCount: 2,  monthlyRevenue: 1040, status: 'pending' },
  ],
  activations: [
    { id: 'act-1', agentId: 'rural-advisor',  userId: 'user-1', userName: 'Maria Garcia',  ispTenantId: 'isp-1', status: 'active', activatedAt: '2026-01-15' },
    { id: 'act-2', agentId: 'edu-tutor',      userId: 'user-1', userName: 'Maria Garcia',  ispTenantId: 'isp-1', status: 'active', activatedAt: '2026-01-20' },
    { id: 'act-3', agentId: 'tech-support',   userId: 'user-2', userName: 'James Wilson', ispTenantId: 'isp-1', status: 'active', activatedAt: '2026-02-01' },
    { id: 'act-4', agentId: 'ag-advisor',     userId: 'user-3', userName: 'Sarah Chen',   ispTenantId: 'isp-1', status: 'active', activatedAt: '2026-02-10' },
  ],
  reviews: [
    { id: 'rev-1', agentId: 'rural-advisor',  userId: 'user-1', rating: 5, comment: 'Incredibly helpful for finding rural development grants!', createdAt: '2026-02-01' },
    { id: 'rev-2', agentId: 'rural-advisor',  userId: 'user-3', rating: 5, comment: 'Helped my community apply for USDA broadband funding.', createdAt: '2026-02-15' },
    { id: 'rev-3', agentId: 'edu-tutor',      userId: 'user-1', rating: 4, comment: 'My kids love it. Really patient with math homework.', createdAt: '2026-03-01' },
    { id: 'rev-4', agentId: 'tech-support',   userId: 'user-2', rating: 5, comment: 'Fixed my connection issue in 5 minutes!', createdAt: '2026-03-05' },
  ],
};

// ── Helpers ────────────────────────────────────────────────────────────────────
async function getEdgeStatus() {
  try {
    const [healthRes, tagsRes] = await Promise.all([
      fetch(`${OPEN_WEBUI_URL}/health`, { signal: AbortSignal.timeout(8000) }).catch(() => null),
      fetch(`${OLLAMA_URL}/api/tags`,   { signal: AbortSignal.timeout(8000) }).catch(() => null),
    ]);
    const health = healthRes?.ok ? await healthRes.json().catch(() => null) : null;
    const tagsData = tagsRes?.ok ? await tagsRes.json().catch(() => null) : null;
    const models = (tagsData?.models || []).map(m => m.name).filter(Boolean);
    return { health, models, ollamaOnline: models.length > 0, edgeOnline: !!health, checkedAt: new Date().toISOString() };
  } catch (err) {
    return { health: null, models: [], ollamaOnline: false, edgeOnline: false, error: String(err), checkedAt: new Date().toISOString() };
  }
}

async function ollamaChat(model, messages) {
  const upstream = await fetch(`${OLLAMA_URL}/api/chat`, {
    method: 'POST', headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ model, messages, stream: false }),
    signal: AbortSignal.timeout(120000),
  });
  if (!upstream.ok) throw new Error(`Ollama ${upstream.status}: ${await upstream.text()}`);
  const data = await upstream.json();
  return data?.message?.content || "I'm unable to respond right now.";
}

// ── Agents ────────────────────────────────────────────────────────────────────
app.get('/api/agents', (req, res) => res.json(db.agents));

app.get('/api/agents/slug/:slug', (req, res) => {
  const a = db.agents.find(x => x.slug === req.params.slug);
  a ? res.json(a) : res.status(404).json({ error: 'Agent not found' });
});

// IMPORTANT: specific routes before :id wildcard
app.get('/api/agents/:id', (req, res) => {
  const a = db.agents.find(x => x.id === req.params.id);
  a ? res.json(a) : res.status(404).json({ error: 'Agent not found' });
});

app.post('/api/agents', (req, res) => {
  const agent = { id: randomUUID().slice(0,8), slug: req.body.name?.toLowerCase().replace(/\s+/g,'-') || randomUUID().slice(0,8), ...req.body, createdAt: new Date().toISOString() };
  db.agents.push(agent);
  res.status(201).json(agent);
});

app.patch('/api/agents/:id', (req, res) => {
  const a = db.agents.find(x => x.id === req.params.id);
  if (!a) return res.status(404).json({ error: 'Not found' });
  Object.assign(a, req.body);
  res.json(a);
});

app.delete('/api/agents/:id', (req, res) => {
  const idx = db.agents.findIndex(x => x.id === req.params.id);
  if (idx === -1) return res.status(404).json({ error: 'Not found' });
  db.agents.splice(idx, 1);
  res.json({ success: true });
});

// Agent chat (per-agent endpoint)
app.post('/api/agents/:id/chat', async (req, res) => {
  const agent = db.agents.find(a => a.id === req.params.id);
  if (!agent) return res.status(404).json({ error: 'Agent not found' });
  const { messages = [] } = req.body;
  const model = agent.modelId || 'phi3:mini';
  const fullMessages = messages[0]?.role === 'system'
    ? messages
    : [{ role: 'system', content: agent.systemPrompt || `You are ${agent.name}. ${agent.description}` }, ...messages];
  try {
    const reply = await ollamaChat(model, fullMessages);
    res.json({ reply, model, agentName: agent.name, agentId: agent.id });
  } catch (err) {
    res.json({ reply: "I'm currently unavailable. Please try again shortly.", error: true, model });
  }
});

// Legacy /api/chat compat (used by older AgentChatDialog — agentId + message + history)
app.post('/api/chat', async (req, res) => {
  const { agentId, message, history = [] } = req.body;
  if (!agentId || !message) return res.status(400).json({ error: 'agentId and message required' });
  const agent = db.agents.find(a => a.id === agentId);
  if (!agent) return res.status(404).json({ error: 'Agent not found' });
  const messages = [];
  if (agent.systemPrompt) messages.push({ role: 'system', content: agent.systemPrompt });
  for (const m of history) { if (m.role && m.content) messages.push(m); }
  messages.push({ role: 'user', content: message });
  const model = agent.modelId || 'phi3:mini';
  try {
    const reply = await ollamaChat(model, messages);
    res.json({ reply, model, agentName: agent.name });
  } catch (err) {
    res.json({ reply: "I'm currently unavailable. Please try again shortly.", error: true });
  }
});

// ── ISP Tenants ───────────────────────────────────────────────────────────────
app.get('/api/isp-tenants', (req, res) => res.json(db.ispTenants));
app.get('/api/isp-tenants/:id', (req, res) => {
  const t = db.ispTenants.find(x => x.id === req.params.id);
  t ? res.json(t) : res.status(404).json({ error: 'Not found' });
});
app.post('/api/isp-tenants', (req, res) => {
  const t = { id: 'isp-' + randomUUID().slice(0,8), ...req.body, createdAt: new Date().toISOString() };
  db.ispTenants.push(t);
  res.status(201).json(t);
});
app.patch('/api/isp-tenants/:id', (req, res) => {
  const t = db.ispTenants.find(x => x.id === req.params.id);
  if (!t) return res.status(404).json({ error: 'Not found' });
  Object.assign(t, req.body);
  res.json(t);
});

// ── Activations ───────────────────────────────────────────────────────────────
app.get('/api/activations', (req, res) => res.json(db.activations));
app.get('/api/activations/agent/:agentId', (req, res) => res.json(db.activations.filter(a => a.agentId === req.params.agentId)));
app.get('/api/activations/user/:userId',  (req, res) => res.json(db.activations.filter(a => a.userId === req.params.userId)));
app.post('/api/activations', (req, res) => {
  const act = { id: 'act-' + randomUUID().slice(0,8), ...req.body, createdAt: new Date().toISOString() };
  db.activations.push(act);
  res.status(201).json(act);
});
app.delete('/api/activations/:id', (req, res) => {
  const idx = db.activations.findIndex(x => x.id === req.params.id);
  if (idx === -1) return res.status(404).json({ error: 'Not found' });
  db.activations.splice(idx, 1);
  res.json({ success: true });
});

// ── Reviews ───────────────────────────────────────────────────────────────────
app.get('/api/reviews', (req, res) => res.json(db.reviews));
app.get('/api/reviews/agent/:agentId', (req, res) => res.json(db.reviews.filter(r => r.agentId === req.params.agentId)));
app.post('/api/reviews', (req, res) => {
  const r = { id: 'rev-' + randomUUID().slice(0,8), ...req.body, createdAt: new Date().toISOString() };
  db.reviews.push(r);
  res.status(201).json(r);
});

// ── Models (live from Ollama) ─────────────────────────────────────────────────
app.get('/api/models', async (req, res) => {
  try {
    const r = await fetch(`${OLLAMA_URL}/api/tags`, { signal: AbortSignal.timeout(8000) });
    const d = await r.json();
    const models = (d.models || []).map(m => ({ id: m.name, name: m.name }));
    res.json({ models, online: true });
  } catch (err) {
    res.json({ models: [{ id: 'phi3:mini', name: 'phi3:mini' }, { id: 'llama3.1:8b', name: 'llama3.1:8b' }], online: false, error: String(err) });
  }
});

// ── Edge status ───────────────────────────────────────────────────────────────
app.get('/api/edge-status', async (req, res) => { res.json(await getEdgeStatus()); });

// ── Health ────────────────────────────────────────────────────────────────────
app.get('/health', (req, res) => res.json({ status: 'ok', service: 'marketplace-backend', ts: new Date().toISOString() }));

const PORT = process.env.PORT || 3011;
app.listen(PORT, '0.0.0.0', () => console.log(`Marketplace backend running on port ${PORT} [full-data-layer]`));
JSEOF
echo -e "  ${GREEN}✓${NC} Marketplace backend written"

# ── Restart ───────────────────────────────────────────────────────────────────
echo ""
echo -e "${YELLOW}▸${NC} Restarting backend containers..."
cd "$EDGE_DIR"
docker compose restart isp-portal-backend marketplace-backend
sleep 5
echo -e "  ${GREEN}✓${NC} Containers restarted"

# ── Verify ────────────────────────────────────────────────────────────────────
echo ""
echo -e "${YELLOW}▸${NC} Verification checks..."

ISP_HEALTH=$(curl -sf http://localhost:3010/health | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('status','?'))" 2>/dev/null || echo "FAIL")
MKT_HEALTH=$(curl -sf http://localhost:3011/health | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('status','?'))" 2>/dev/null || echo "FAIL")
echo -e "  ISP health:        ${ISP_HEALTH}"
echo -e "  Marketplace health: ${MKT_HEALTH}"

DASHBOARD=$(curl -sf http://localhost:3010/api/dashboard | python3 -c "import json,sys; d=json.load(sys.stdin); print(f'terminals={d[\"totalTerminals\"]} subs={d[\"activeSubscribers\"]} models={d[\"liveModels\"]}')" 2>/dev/null || echo "FAIL")
echo -e "  Dashboard:         ${DASHBOARD}"

AGENTS=$(curl -sf http://localhost:3011/api/agents | python3 -c "import json,sys; d=json.load(sys.stdin); print(f'{len(d)} agents: ' + ', '.join(a[\"name\"] for a in d[:3]) + '...')" 2>/dev/null || echo "FAIL")
echo -e "  Agents:            ${AGENTS}"

MODELS=$(curl -sf http://localhost:3011/api/models | python3 -c "import json,sys; d=json.load(sys.stdin); print('online=' + str(d['online']) + ' models=' + ','.join(m['id'] for m in d['models']))" 2>/dev/null || echo "FAIL")
echo -e "  Models:            ${MODELS}"

echo -e "${YELLOW}▸${NC} Testing agent chat (phi3:mini)..."
CHAT=$(curl -sf -X POST http://localhost:3011/api/agents/tech-support/chat \
  -H "Content-Type: application/json" \
  -d '{"messages":[{"role":"user","content":"Say CHAT_OK and nothing else"}]}' \
  | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('reply','')[:80])" 2>/dev/null || echo "FAIL")
echo -e "  Chat reply:        ${CHAT}"

echo ""
echo -e "${GREEN}══════════════════════════════════════════════════${NC}"
echo -e "${GREEN}  Full backends deployed — ready for frontend build ${NC}"
echo -e "${GREEN}══════════════════════════════════════════════════${NC}"
echo ""
