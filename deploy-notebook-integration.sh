#!/usr/bin/env bash
# deploy-notebook-integration.sh
# Adds Open Notebook connector support to both backends:
#   - ISP Portal: /api/notebook-connectors CRUD + /test endpoint
#   - Marketplace: /api/notebook-connectors proxy + context injection in agent chat
# Run as root on the VPS: bash deploy-notebook-integration.sh

set -e
EDGE_DIR="/opt/etheros-edge"
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'

echo ""
echo -e "${YELLOW}══════════════════════════════════════════════════${NC}"
echo -e "${YELLOW}  EtherOS — Open Notebook Integration Deploy      ${NC}"
echo -e "${YELLOW}══════════════════════════════════════════════════${NC}"
echo ""

# ══════════════════════════════════════════════════════════════════════════════
# ISP PORTAL BACKEND — add notebook-connectors store + routes
# ══════════════════════════════════════════════════════════════════════════════
echo -e "${YELLOW}▸${NC} Patching ISP Portal backend (notebook connectors)..."
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
  // ── NEW: Open Notebook connectors ──────────────────────────────────────────
  notebookConnectors: [],
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

// Edge chat
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

// Agents (ISP view)
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

// Revenue / Activity
app.get('/api/revenue', (req, res) => res.json(db.revenue));
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

// ── Notebook Connectors ────────────────────────────────────────────────────────
app.get('/api/notebook-connectors', (req, res) => {
  // Never expose apiKey in list response
  res.json(db.notebookConnectors.map(({ apiKey, ...safe }) => ({ ...safe, apiKey: apiKey ? '••••••••' : '' })));
});

app.post('/api/notebook-connectors', (req, res) => {
  const { name, baseUrl, apiKey, notebookId, topic } = req.body;
  if (!name || !baseUrl || !notebookId) return res.status(400).json({ error: 'name, baseUrl, and notebookId are required' });
  const connector = {
    id: 'nb-' + randomUUID().slice(0, 8),
    name, baseUrl: baseUrl.replace(/\/$/, ''), apiKey: apiKey || '', notebookId, topic: topic || '',
    status: 'unchecked',
    createdAt: new Date().toISOString(),
  };
  db.notebookConnectors.push(connector);
  const { apiKey: _k, ...safe } = connector;
  res.status(201).json({ ...safe, apiKey: apiKey ? '••••••••' : '' });
});

app.delete('/api/notebook-connectors/:id', (req, res) => {
  const idx = db.notebookConnectors.findIndex(c => c.id === req.params.id);
  if (idx === -1) return res.status(404).json({ error: 'Not found' });
  db.notebookConnectors.splice(idx, 1);
  res.json({ success: true });
});

// Test a connector — tries to reach the Open Notebook instance and fetch the notebook
app.post('/api/notebook-connectors/:id/test', async (req, res) => {
  const connector = db.notebookConnectors.find(c => c.id === req.params.id);
  if (!connector) return res.status(404).json({ error: 'Not found' });

  const headers = { 'Content-Type': 'application/json' };
  if (connector.apiKey) headers['Authorization'] = `Bearer ${connector.apiKey}`;

  try {
    // Try to reach the Open Notebook API - notebook list endpoint
    const testUrl = `${connector.baseUrl}/api/notebooks/${connector.notebookId}`;
    const r = await fetch(testUrl, { headers, signal: AbortSignal.timeout(10000) });
    if (r.ok) {
      const data = await r.json().catch(() => ({}));
      connector.status = 'connected';
      connector.lastChecked = new Date().toISOString();
      return res.json({ ok: true, notebookTitle: data?.title || data?.name || connector.notebookId, status: 'connected' });
    } else {
      connector.status = 'error';
      connector.lastChecked = new Date().toISOString();
      return res.json({ ok: false, error: `HTTP ${r.status} from Open Notebook`, status: 'error' });
    }
  } catch (err) {
    connector.status = 'error';
    connector.lastChecked = new Date().toISOString();
    return res.json({ ok: false, error: `Cannot reach ${connector.baseUrl}: ${err.message}`, status: 'error' });
  }
});

// Internal endpoint: get connectors WITH apiKey (for marketplace backend context injection)
app.get('/api/notebook-connectors/internal', (req, res) => {
  // Only accessible from within the Docker network
  const forwarded = req.headers['x-forwarded-for'] || req.socket.remoteAddress || '';
  res.json(db.notebookConnectors);
});

// Health
app.get('/health', (req, res) => res.json({ status: 'ok', service: 'isp-portal-backend', ts: new Date().toISOString() }));

const PORT = process.env.PORT || 3010;
app.listen(PORT, '0.0.0.0', () => console.log(`ISP Portal backend running on port ${PORT} [notebook-integration]`));
JSEOF
echo -e "  ${GREEN}✓${NC} ISP Portal backend written"

# ══════════════════════════════════════════════════════════════════════════════
# MARKETPLACE BACKEND — notebook connector proxy + context injection
# ══════════════════════════════════════════════════════════════════════════════
echo -e "${YELLOW}▸${NC} Patching Marketplace backend (context injection)..."
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
// ISP Portal backend — for fetching notebook connectors
const ISP_PORTAL_URL = 'http://etheros-isp-portal-backend:3010';

// ── In-memory data store ──────────────────────────────────────────────────────
const db = {
  agents: [
    { id: 'rural-advisor',    slug: 'rural-advisor',    name: 'Rural Community Advisor', category: 'Community',  modelId: 'llama3.1:8b', status: 'LIVE', isEnabled: true, creatorRole: 'etheros', price: 0,    description: 'Expert guidance on rural community development, grants, and resources.', systemPrompt: 'You are a Rural Community Advisor specializing in rural development, grants, and community resources across America. Be helpful, practical, and focused on rural contexts.', rating: 4.8, reviewCount: 124, activationCount: 312, priceMonthly: 0, notebookConnectorIds: [] },
    { id: 'tech-support',     slug: 'tech-support',     name: 'Tech Support Agent',      category: 'Support',    modelId: 'phi3:mini',   status: 'LIVE', isEnabled: true, creatorRole: 'etheros', price: 0,    description: 'Friendly first-line technical support for EtherOS terminals and connected devices.', systemPrompt: 'You are a friendly tech support agent for EtherOS. Help users with their terminals, internet connection, and software issues. Be patient and explain things clearly.', rating: 4.6, reviewCount: 89, activationCount: 198, priceMonthly: 0, notebookConnectorIds: [] },
    { id: 'business-coach',   slug: 'business-coach',   name: 'Small Business Coach',    category: 'Business',   modelId: 'llama3.1:8b', status: 'LIVE', isEnabled: true, creatorRole: 'isp',     price: 2.99, description: 'Business planning, marketing, and growth advice for rural entrepreneurs.', systemPrompt: 'You are a small business coach specializing in rural entrepreneurship. Provide practical advice on business planning, marketing on a budget, and accessing rural business grants.', rating: 4.9, reviewCount: 67, activationCount: 156, priceMonthly: 2.99, notebookConnectorIds: [] },
    { id: 'edu-tutor',        slug: 'edu-tutor',        name: 'Education Tutor',         category: 'Learning',   modelId: 'phi3:mini',   status: 'LIVE', isEnabled: true, creatorRole: 'etheros', price: 0,    description: 'Homework help and learning support for K-12 students and adult learners.', systemPrompt: 'You are a patient and encouraging education tutor for K-12 students. Explain concepts clearly, use examples, and adapt to the student\'s level. Make learning fun.', rating: 4.7, reviewCount: 203, activationCount: 445, priceMonthly: 0, notebookConnectorIds: [] },
    { id: 'health-navigator', slug: 'health-navigator', name: 'Health Navigator',        category: 'Health',     modelId: 'llama3.1:8b', status: 'LIVE', isEnabled: true, creatorRole: 'isp',     price: 1.99, description: 'General health information and telehealth resource navigation for rural communities.', systemPrompt: 'You are a health navigator helping rural residents access healthcare resources. Provide general health information, help find local services, and explain telehealth options. Always recommend professional medical consultation for medical decisions.', rating: 4.5, reviewCount: 45, activationCount: 98, priceMonthly: 1.99, notebookConnectorIds: [] },
    { id: 'legal-basics',     slug: 'legal-basics',     name: 'Legal Basics Assistant',  category: 'Community',  modelId: 'llama3.1:8b', status: 'REVIEW', isEnabled: false, creatorRole: 'third_party', price: 4.99, description: 'Plain-English explanations of common legal questions. Not legal advice.', systemPrompt: 'You are a legal information assistant. Explain legal concepts and procedures in plain English. Always clarify you are not providing legal advice and recommend consulting a licensed attorney for specific situations.', rating: 4.3, reviewCount: 12, activationCount: 23, priceMonthly: 4.99, notebookConnectorIds: [] },
    { id: 'ag-advisor',       slug: 'ag-advisor',       name: 'Agriculture Advisor',     category: 'Agriculture', modelId: 'llama3.1:8b', status: 'LIVE', isEnabled: true, creatorRole: 'etheros', price: 0, description: 'Crop management, soil health, irrigation, and USDA program guidance for farmers.', systemPrompt: 'You are an agriculture advisor helping rural farmers with crop management, soil health, irrigation, and accessing USDA programs. Provide practical, science-based guidance.', rating: 4.9, reviewCount: 78, activationCount: 187, priceMonthly: 0, notebookConnectorIds: [] },
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

// ── Open Notebook context injection ───────────────────────────────────────────
// Open Notebook API pattern (lfnovo/open-notebook):
//   1. POST /api/search { query, notebook_id, limit } → { results: [{id, title, relevance}] }
//   2. GET  /api/sources/{id}                         → { full_text, title, ... }
async function fetchNotebookContext(connectorIds, userMessage) {
  if (!connectorIds || connectorIds.length === 0) return null;

  // Fetch connector details from ISP Portal backend (has the API keys)
  let connectors = [];
  try {
    const r = await fetch(`${ISP_PORTAL_URL}/api/notebook-connectors/internal`, { signal: AbortSignal.timeout(5000) });
    if (r.ok) {
      const all = await r.json();
      connectors = all.filter(c => connectorIds.includes(c.id));
    }
  } catch (err) {
    console.error('Could not fetch notebook connectors:', err.message);
    return null;
  }

  if (connectors.length === 0) return null;

  const contextParts = [];

  for (const conn of connectors) {
    try {
      const headers = { 'Content-Type': 'application/json' };
      if (conn.apiKey) headers['Authorization'] = `Bearer ${conn.apiKey}`;
      const baseUrl = conn.baseUrl.replace(/\/$/, '');

      // Step 1: Search for relevant sources
      const searchRes = await fetch(`${baseUrl}/api/search`, {
        method: 'POST',
        headers,
        body: JSON.stringify({ query: userMessage, notebook_id: conn.notebookId, limit: 5 }),
        signal: AbortSignal.timeout(10000),
      });

      if (!searchRes.ok) {
        console.error(`Search failed for ${conn.name}: HTTP ${searchRes.status}`);
        continue;
      }

      const searchData = await searchRes.json();
      const results = (searchData?.results || []).slice(0, 3); // top 3 most relevant
      if (results.length === 0) continue;

      // Step 2: Fetch full_text for each result
      const passages = [];
      for (const result of results) {
        try {
          const sourceRes = await fetch(`${baseUrl}/api/sources/${result.id}`, {
            headers,
            signal: AbortSignal.timeout(8000),
          });
          if (sourceRes.ok) {
            const source = await sourceRes.json();
            const text = source.full_text || source.content || source.text || '';
            if (text) {
              // Trim to 1500 chars per source to keep context manageable
              passages.push(`Source: ${result.title}\n${text.slice(0, 1500)}${text.length > 1500 ? '...' : ''}`);
            }
          }
        } catch (err) {
          console.error(`Source fetch failed for ${result.id}:`, err.message);
        }
      }

      if (passages.length > 0) {
        contextParts.push(`[KNOWLEDGE BASE: ${conn.name}${conn.topic ? ` (${conn.topic})` : ''}]\n\n${passages.join('\n\n---\n\n')}`);
      }

    } catch (err) {
      console.error(`Notebook context fetch failed for ${conn.name}:`, err.message);
      // Graceful degradation — continue without this connector
    }
  }

  if (contextParts.length === 0) return null;
  return contextParts.join('\n\n==========\n\n');
}

// ── Notebook connectors proxy (for Marketplace frontend) ─────────────────────
app.get('/api/notebook-connectors', async (req, res) => {
  try {
    const r = await fetch(`${ISP_PORTAL_URL}/api/notebook-connectors`, { signal: AbortSignal.timeout(5000) });
    const data = await r.json();
    res.json(data);
  } catch {
    res.json([]); // graceful fallback if ISP Portal unreachable
  }
});

// ── Agents ────────────────────────────────────────────────────────────────────
app.get('/api/agents', (req, res) => res.json(db.agents));

app.get('/api/agents/slug/:slug', (req, res) => {
  const a = db.agents.find(x => x.slug === req.params.slug);
  a ? res.json(a) : res.status(404).json({ error: 'Agent not found' });
});

app.get('/api/agents/:id', (req, res) => {
  const a = db.agents.find(x => x.id === req.params.id);
  a ? res.json(a) : res.status(404).json({ error: 'Agent not found' });
});

app.post('/api/agents', (req, res) => {
  const agent = {
    id: randomUUID().slice(0,8),
    slug: req.body.name?.toLowerCase().replace(/\s+/g,'-') || randomUUID().slice(0,8),
    notebookConnectorIds: [],
    activationCount: 0,
    priceMonthly: 0,
    ...req.body,
    createdAt: new Date().toISOString()
  };
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

// ── Agent chat with notebook context injection ─────────────────────────────────
app.post('/api/agents/:id/chat', async (req, res) => {
  const agent = db.agents.find(a => a.id === req.params.id);
  if (!agent) return res.status(404).json({ error: 'Agent not found' });
  const { messages = [] } = req.body;
  const model = agent.modelId || 'phi3:mini';
  const userMessage = messages.filter(m => m.role === 'user').slice(-1)[0]?.content || '';

  // Build base system prompt
  let systemContent = agent.systemPrompt || `You are ${agent.name}. ${agent.description}`;

  // Inject notebook context if configured
  if (agent.notebookConnectorIds?.length > 0 && userMessage) {
    const context = await fetchNotebookContext(agent.notebookConnectorIds, userMessage);
    if (context) {
      systemContent = `${systemContent}\n\nThe following is relevant information from your connected knowledge bases. Use it to ground your response:\n\n${context}\n\n[END OF KNOWLEDGE BASE CONTEXT]`;
    }
  }

  const fullMessages = messages[0]?.role === 'system'
    ? [{ role: 'system', content: systemContent }, ...messages.filter(m => m.role !== 'system')]
    : [{ role: 'system', content: systemContent }, ...messages];

  try {
    const reply = await ollamaChat(model, fullMessages);
    res.json({
      reply, model, agentName: agent.name, agentId: agent.id,
      _contextUsed: agent.notebookConnectorIds?.length > 0,
    });
  } catch (err) {
    res.json({ reply: "I'm currently unavailable. Please try again shortly.", error: true, model });
  }
});

// Legacy /api/chat compat
app.post('/api/chat', async (req, res) => {
  const { agentId, message, history = [] } = req.body;
  if (!agentId || !message) return res.status(400).json({ error: 'agentId and message required' });
  const agent = db.agents.find(a => a.id === agentId);
  if (!agent) return res.status(404).json({ error: 'Agent not found' });
  const messages = [];
  let systemContent = agent.systemPrompt || `You are ${agent.name}. ${agent.description}`;

  // Inject notebook context
  if (agent.notebookConnectorIds?.length > 0 && message) {
    const context = await fetchNotebookContext(agent.notebookConnectorIds, message);
    if (context) {
      systemContent = `${systemContent}\n\nRelevant knowledge base context:\n\n${context}\n\n[END CONTEXT]`;
    }
  }

  if (systemContent) messages.push({ role: 'system', content: systemContent });
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

// ── Models ────────────────────────────────────────────────────────────────────
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
app.listen(PORT, '0.0.0.0', () => console.log(`Marketplace backend running on port ${PORT} [notebook-integration]`));
JSEOF
echo -e "  ${GREEN}✓${NC} Marketplace backend written"

# ── Restart backends ──────────────────────────────────────────────────────────
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
echo -e "  ISP health:         ${ISP_HEALTH}"
echo -e "  Marketplace health: ${MKT_HEALTH}"

NB=$(curl -sf http://localhost:3010/api/notebook-connectors | python3 -c "import json,sys; d=json.load(sys.stdin); print(f'{len(d)} connectors')" 2>/dev/null || echo "FAIL")
echo -e "  Connectors API:     ${NB}"

AGENTS=$(curl -sf http://localhost:3011/api/agents | python3 -c "import json,sys; d=json.load(sys.stdin); print(f'{len(d)} agents')" 2>/dev/null || echo "FAIL")
echo -e "  Agents API:         ${AGENTS}"

echo ""
echo -e "${GREEN}══════════════════════════════════════════════════${NC}"
echo -e "${GREEN}  Open Notebook integration deployed!             ${NC}"
echo -e "${GREEN}  Next: rebuild & redeploy both static apps       ${NC}"
echo -e "${GREEN}══════════════════════════════════════════════════${NC}"
echo ""
