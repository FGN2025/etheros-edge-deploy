'use strict';
/**
 * routes/agents.js — Agent catalog, ISP-level enable/disable, terminal browse
 */

const { Router } = require('express');
const { randomUUID, createHash } = require('crypto');
const { getDb, agentFromRow, subscriberFromRow } = require('../db');

const PLAN_AGENT_LIMITS = { personal: 3, professional: 10, charter: 999 };

function parseToken(token) {
  try {
    const [subscriberId, ts] = Buffer.from(token, 'base64url').toString('utf8').split('.');
    if (!subscriberId || Date.now() - parseInt(ts, 10) > 8 * 3600_000) return null;
    return subscriberId;
  } catch { return null; }
}

const DEFAULT_AGENTS = [
  { id:'agent-001', name:'Rural Support Assistant', slug:'rural-support', description:'Answers common rural broadband questions, outage updates, and billing FAQs for end users.', category:'Support', creatorRole:'etheros', status:'live', pricingType:'free', priceMonthly:0, activationCount:0, isEnabled:true, modelId:'llama3.2:3b', systemPrompt:'You are a helpful rural ISP support assistant. Answer questions about internet service, outages, billing, and equipment in a friendly and simple way. Respond concisely. Use short paragraphs or bullet points. Avoid long run-on responses.' },
  { id:'agent-002', name:'Community Bulletin', slug:'community-bulletin', description:'Shares local news, events, and community announcements tailored to the subscriber\'s area.', category:'Community', creatorRole:'etheros', status:'live', pricingType:'free', priceMonthly:0, activationCount:0, isEnabled:true, modelId:'llama3.2:3b', systemPrompt:'You are a friendly community assistant for a rural area. Share local news, events, weather, and community information. Respond concisely. Use short paragraphs or bullet points. Avoid long run-on responses.' },
  { id:'agent-003', name:'HomeSchool Tutor', slug:'homeschool-tutor', description:'Patient K-12 tutoring assistant for homeschool families covering math, science, reading, and history.', category:'Learning', creatorRole:'etheros', status:'live', pricingType:'free', priceMonthly:0, activationCount:0, isEnabled:true, modelId:'llama3.2:3b', systemPrompt:'You are a patient, encouraging K-12 tutor. Help students with math, science, reading, writing, and history. Explain concepts simply and check for understanding. Respond concisely. Use short paragraphs or bullet points. Avoid long run-on responses.' },
  { id:'agent-004', name:'Farm & Ranch Advisor', slug:'farm-ranch-advisor', description:'Agronomic and livestock guidance for small farms — planting schedules, soil health, pest management.', category:'Agriculture', creatorRole:'etheros', status:'live', pricingType:'free', priceMonthly:0, activationCount:0, isEnabled:true, modelId:'llama3.2:3b', systemPrompt:'You are an agricultural advisor for small farms and ranches. Provide practical guidance on crops, livestock, soil health, irrigation, and pest management. Respond concisely. Use short paragraphs or bullet points. Avoid long run-on responses.' },
  { id:'agent-005', name:'Health Navigator', slug:'health-navigator', description:'General health information, symptom guidance, and telehealth navigation for rural households.', category:'Health', creatorRole:'etheros', status:'live', pricingType:'free', priceMonthly:0, activationCount:0, isEnabled:true, modelId:'llama3.2:3b', systemPrompt:'You are a general health information assistant. Provide helpful health information, help users understand symptoms, and guide them to appropriate care. Always recommend consulting a doctor for medical decisions. Respond concisely. Use short paragraphs or bullet points. Avoid long run-on responses.' },
  { id:'agent-006', name:'Small Biz Coach', slug:'small-biz-coach', description:'Business planning, marketing, and operations advice for rural small business owners.', category:'Business', creatorRole:'etheros', status:'live', pricingType:'addon', priceMonthly:4.99, activationCount:0, isEnabled:true, modelId:'llama3.2:3b', systemPrompt:'You are a small business coach for rural entrepreneurs. Help with business planning, marketing strategies, financial basics, and operational challenges. Respond concisely. Use short paragraphs or bullet points. Avoid long run-on responses.' },
  { id:'agent-007', name:'Legal Q&A', slug:'legal-qa', description:'Plain-language explanations of common legal questions — leases, contracts, employment, and property.', category:'Business', creatorRole:'etheros', status:'live', pricingType:'addon', priceMonthly:4.99, activationCount:0, isEnabled:true, modelId:'llama3.2:3b', systemPrompt:'You provide plain-language explanations of common legal concepts. Always clarify you are not a lawyer and recommend consulting one for specific legal advice. Respond concisely. Use short paragraphs or bullet points. Avoid long run-on responses.' },
  { id:'agent-008', name:'Dev Sandbox', slug:'dev-sandbox', description:'Code assistant for developers — debugging, snippets, and architecture guidance across popular languages.', category:'Development', creatorRole:'etheros', status:'live', pricingType:'addon', priceMonthly:4.99, activationCount:0, isEnabled:false, modelId:'llama3.2:3b', systemPrompt:'You are an expert software developer assistant. Help with code debugging, writing code snippets, explaining concepts, and software architecture across all major languages. Respond concisely. Use short paragraphs or bullet points. Avoid long run-on responses.' },
  { id:'agent-009', name:'Data Analyst', slug:'data-analyst', description:'Helps interpret spreadsheets, charts, and business data — ideal for small business analytics.', category:'Analytics', creatorRole:'etheros', status:'live', pricingType:'addon', priceMonthly:9.99, activationCount:0, isEnabled:false, modelId:'llama3.2:3b', systemPrompt:'You are a data analysis assistant. Help users understand their data, create summaries, identify trends, and make data-driven decisions. Respond concisely. Use short paragraphs or bullet points. Avoid long run-on responses.' },
  { id:'agent-010', name:'Creative Writer', slug:'creative-writer', description:'Storytelling, poetry, marketing copy, and creative writing assistance for individuals and businesses.', category:'Creative', creatorRole:'etheros', status:'live', pricingType:'free', priceMonthly:0, activationCount:0, isEnabled:true, modelId:'llama3.2:3b', systemPrompt:'You are a creative writing assistant. Help with stories, poems, marketing copy, blog posts, and any creative writing project. Respond concisely. Use short paragraphs or bullet points. Avoid long run-on responses.' },
];

module.exports = function agentsRouter(DATA_DIR) {
  const router = Router();
  function db() { return getDb(DATA_DIR); }

  function seedDefaults(d) {
    const count = d.prepare('SELECT COUNT(*) as n FROM agents').get().n;
    if (count > 0) return;
    const ins = d.prepare(`INSERT OR IGNORE INTO agents
      (id,name,slug,description,category,creator_role,status,pricing_type,price_monthly,is_enabled,model_id,system_prompt,notebook_sources,activation_count)
      VALUES (@id,@name,@slug,@description,@category,@creator_role,@status,@pricing_type,@price_monthly,@is_enabled,@model_id,@system_prompt,@notebook_sources,@activation_count)`);
    d.transaction(rows => rows.forEach(a => ins.run({
      id:a.id, name:a.name, slug:a.slug, description:a.description, category:a.category,
      creator_role:a.creatorRole, status:a.status, pricing_type:a.pricingType,
      price_monthly:a.priceMonthly, is_enabled:a.isEnabled?1:0,
      model_id:a.modelId, system_prompt:a.systemPrompt,
      notebook_sources:'[]', activation_count:a.activationCount||0,
    })))(DEFAULT_AGENTS);
  }

  // GET /api/agents — with live activation counts from subscriber active_agent_ids
  router.get('/', (req, res) => {
    const d = db();
    seedDefaults(d);
    const rows = d.prepare('SELECT * FROM agents ORDER BY name').all();
    const subRows = d.prepare('SELECT active_agent_ids FROM subscribers').all();
    const countMap = {};
    for (const sr of subRows) {
      const ids = JSON.parse(sr.active_agent_ids || '[]');
      ids.forEach(id => { countMap[id] = (countMap[id] || 0) + 1; });
    }
    res.json(rows.map(r => ({ ...agentFromRow(r), activationCount: countMap[r.id] || r.activation_count })));
  });

  // GET /api/agents/browse — subscriber-facing (terminal), requires Bearer token
  router.get('/browse', (req, res) => {
    const token = (req.headers.authorization || '').replace('Bearer ', '');
    const subscriberId = parseToken(token);
    if (!subscriberId) return res.status(401).json({ error: 'Invalid or expired session' });
    const d = db();
    const subRow = d.prepare('SELECT * FROM subscribers WHERE id=?').get(subscriberId);
    if (!subRow) return res.status(404).json({ error: 'Subscriber not found' });
    const sub = subscriberFromRow(subRow);
    seedDefaults(d);
    const rows = d.prepare('SELECT * FROM agents WHERE is_enabled=1 AND status=\'live\'').all();
    const activeIds = sub.activeAgentIds;
    const limit = PLAN_AGENT_LIMITS[sub.plan] || 3;
    res.json({
      agents: rows.map(r => ({ ...agentFromRow(r), activated: activeIds.includes(r.id) })),
      activeAgentIds: activeIds, limit,
      slotsUsed: activeIds.length, slotsRemaining: Math.max(0, limit - activeIds.length),
      plan: sub.plan,
    });
  });

  // POST /api/agents
  router.post('/', (req, res) => {
    const { name, description, category, modelId, systemPrompt, pricingType, priceMonthly, notebookSources } = req.body;
    if (!name || !description) return res.status(400).json({ error: 'name and description are required' });
    const d = db();
    const agent = {
      id: 'agent-' + randomUUID().slice(0, 8), name, description,
      slug: name.toLowerCase().replace(/[^a-z0-9]+/g, '-'),
      category: category || 'Productivity', creator_role: 'isp', status: 'live',
      pricing_type: pricingType || 'free', price_monthly: priceMonthly || 0,
      is_enabled: 1, model_id: modelId || 'llama3.2:3b',
      system_prompt: systemPrompt || '',
      notebook_sources: JSON.stringify(Array.isArray(notebookSources) ? notebookSources : []),
      activation_count: 0,
    };
    d.prepare(`INSERT INTO agents
      (id,name,slug,description,category,creator_role,status,pricing_type,price_monthly,is_enabled,model_id,system_prompt,notebook_sources,activation_count)
      VALUES (@id,@name,@slug,@description,@category,@creator_role,@status,@pricing_type,@price_monthly,@is_enabled,@model_id,@system_prompt,@notebook_sources,@activation_count)
    `).run(agent);
    res.status(201).json(agentFromRow(d.prepare('SELECT * FROM agents WHERE id=?').get(agent.id)));
  });

  // PATCH /api/agents/:id/toggle
  router.patch('/:id/toggle', (req, res) => {
    const d = db();
    const row = d.prepare('SELECT * FROM agents WHERE id=?').get(req.params.id);
    if (!row) return res.status(404).json({ error: 'Agent not found' });
    const newEnabled = req.body.enabled !== undefined ? (req.body.enabled ? 1 : 0) : (row.is_enabled ? 0 : 1);
    d.prepare('UPDATE agents SET is_enabled=? WHERE id=?').run(newEnabled, req.params.id);
    res.json(agentFromRow(d.prepare('SELECT * FROM agents WHERE id=?').get(req.params.id)));
  });

  // PATCH /api/agents/:id
  router.patch('/:id', (req, res) => {
    const d = db();
    const row = d.prepare('SELECT * FROM agents WHERE id=?').get(req.params.id);
    if (!row) return res.status(404).json({ error: 'Agent not found' });
    const b = req.body;
    const sets = []; const params = { id: req.params.id };
    const map = { name:'name', description:'description', category:'category', status:'status',
                  modelId:'model_id', systemPrompt:'system_prompt Respond concisely. Use short paragraphs or bullet points. Avoid long run-on responses.',
                  pricingType:'pricing_type', priceMonthly:'price_monthly' };
    for (const [k,v] of Object.entries(map)) {
      if (b[k] !== undefined) { sets.push(`${v}=@${v}`); params[v] = b[k]; }
    }
    if (b.isEnabled !== undefined) { sets.push('is_enabled=@is_enabled'); params.is_enabled = b.isEnabled ? 1 : 0; }
    if (b.notebookSources !== undefined) { sets.push('notebook_sources=@notebook_sources'); params.notebook_sources = JSON.stringify(b.notebookSources); }
    if (sets.length > 0) d.prepare(`UPDATE agents SET ${sets.join(',')} WHERE id=@id`).run(params);
    res.json(agentFromRow(d.prepare('SELECT * FROM agents WHERE id=?').get(req.params.id)));
  });

  // DELETE /api/agents/:id
  router.delete('/:id', (req, res) => {
    const d = db();
    const row = d.prepare('SELECT * FROM agents WHERE id=?').get(req.params.id);
    if (!row) return res.status(404).json({ error: 'Agent not found' });
    if (row.creator_role !== 'isp') return res.status(403).json({ error: 'Cannot delete EtherOS agents' });
    d.prepare('DELETE FROM agents WHERE id=?').run(req.params.id);
    res.json({ ok: true });
  });

  return router;
};
