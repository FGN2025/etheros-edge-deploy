'use strict';
/**
 * routes/subscribers.js — Subscriber CRUD, PIN auth, agent slots, Stripe billing
 */

const { Router } = require('express');
const { randomUUID, createHash } = require('crypto');
const { getDb, subscriberFromRow } = require('../db');

const PLAN_PRICES      = { personal: 14.99, professional: 39.99, charter: 99.99 };
const PLAN_AGENT_LIMITS = { personal: 3, professional: 10, charter: 999 };
const SUBSCRIBER_PLANS = {
  personal:     { name: 'Personal',     priceMonthly: 1499, priceId: 'price_1TBPB5ERnCKuXiJaJSsWJBTw' },
  professional: { name: 'Professional', priceMonthly: 3999, priceId: 'price_1TBPCzERnCKuXiJagZEPZAVk' },
  charter:      { name: 'Charter',      priceMonthly: 9999, priceId: 'price_1TBPCzERnCKuXiJaB8DWJ84N' },
};

// ── Token helpers ─────────────────────────────────────────────────────────────
function makeToken(subscriberId) {
  return Buffer.from(`${subscriberId}.${Date.now()}`).toString('base64url');
}
function parseToken(token) {
  try {
    const [subscriberId, ts] = Buffer.from(token, 'base64url').toString('utf8').split('.');
    if (!subscriberId || Date.now() - parseInt(ts, 10) > 8 * 3600_000) return null;
    return subscriberId;
  } catch { return null; }
}
function subscriberPin(sub) {
  return createHash('sha256').update(sub.id + sub.email).digest('hex').slice(-6).toUpperCase();
}

module.exports = function subscribersRouter(DATA_DIR, loadSettings, getStripe, portalUrl) {
  const router = Router();
  function db() { return getDb(DATA_DIR); }

  // ── PIN auth (terminal-facing, public) ────────────────────────────────────
  router.post('/auth', (req, res) => {
    const { pin } = req.body || {};
    if (!pin) return res.status(400).json({ error: 'pin required' });
    const rows = db().prepare('SELECT * FROM subscribers').all();
    const row = rows.find(r => subscriberPin(subscriberFromRow(r)) === String(pin).toUpperCase());
    if (!row) return res.status(401).json({ error: 'PIN not recognised' });
    const sub = subscriberFromRow(row);
    if (sub.status === 'suspended') return res.status(403).json({ error: 'Account suspended' });
    const token = makeToken(sub.id);
    res.json({ ok: true, subscriberId: sub.id, name: sub.name, plan: sub.plan, token });
  });

  // GET /api/subscribers/auth/pin/:id — admin: look up PIN
  router.get('/auth/pin/:id', (req, res) => {
    const row = db().prepare('SELECT * FROM subscribers WHERE id=?').get(req.params.id);
    if (!row) return res.status(404).json({ error: 'Not found' });
    res.json({ pin: subscriberPin(subscriberFromRow(row)) });
  });

  // GET /api/subscribers/me — token → subscriber record
  router.get('/me', (req, res) => {
    const id = parseToken((req.headers.authorization || '').replace('Bearer ', ''));
    if (!id) return res.status(401).json({ error: 'Invalid or expired token' });
    const row = db().prepare('SELECT * FROM subscribers WHERE id=?').get(id);
    if (!row) return res.status(404).json({ error: 'Subscriber not found' });
    res.json(subscriberFromRow(row));
  });

  // ── Batch Stripe invite (must be before /:id routes) ──────────────────────
  router.post('/billing/batch-invite', async (req, res) => {
    const stripe = getStripe();
    if (!stripe) return res.status(400).json({ error: 'Stripe not configured' });
    const d = db();
    const rows = d.prepare(`SELECT * FROM subscribers WHERE billing_status IS NULL OR billing_status='none'`).all();
    const { successUrl, cancelUrl } = req.body;
    let invited = 0, skipped = 0, errors = 0;
    for (const row of rows) {
      const sub = subscriberFromRow(row);
      const plan = SUBSCRIBER_PLANS[sub.plan];
      if (!plan) { skipped++; continue; }
      try {
        const session = await stripe.checkout.sessions.create({
          mode: 'subscription',
          line_items: [{ price: plan.priceId, quantity: 1 }],
          customer_email: sub.email,
          success_url: successUrl || portalUrl('/isp-portal/#/subscribers?billing=success'),
          cancel_url: cancelUrl || portalUrl('/isp-portal/#/subscribers?billing=canceled'),
          metadata: { subscriberId: sub.id, plan: sub.plan },
        });
        d.prepare(`UPDATE subscribers SET billing_status='invited',billing_invited_at=?,stripe_checkout_session_id=? WHERE id=?`)
          .run(new Date().toISOString(), session.id, sub.id);
        invited++;
      } catch (err) { console.error('batch-invite error:', err.message); errors++; }
    }
    const total = d.prepare('SELECT COUNT(*) as n FROM subscribers').get().n;
    res.json({ invited, skipped, errors, total });
  });

  // ── CRUD ─────────────────────────────────────────────────────────────────
  router.get('/', (req, res) => {
    const rows = db().prepare('SELECT * FROM subscribers ORDER BY joined_at DESC').all();
    res.json(rows.map(subscriberFromRow));
  });

  router.post('/', (req, res) => {
    const { name, email, plan } = req.body;
    if (!name || !email || !plan) return res.status(400).json({ error: 'name, email and plan are required' });
    const d = db();
    const exists = d.prepare('SELECT id FROM subscribers WHERE email=?').get(email);
    if (exists) return res.status(409).json({ error: 'Email already exists' });
    const sub = {
      id: randomUUID(), name, email, plan, status: 'active',
      agents_active: 0, monthly_spend: PLAN_PRICES[plan] || 0,
      joined_at: new Date().toISOString(), isp: req.body.isp || null,
      stripe_customer_id: null, stripe_subscription_id: null,
      stripe_checkout_session_id: null, billing_status: 'none',
      billing_invited_at: null, current_period_end: null,
      cancel_at_period_end: 0, active_agent_ids: '[]',
    };
    d.prepare(`INSERT INTO subscribers
      (id,name,email,plan,status,agents_active,monthly_spend,joined_at,isp,
       stripe_customer_id,stripe_subscription_id,stripe_checkout_session_id,
       billing_status,billing_invited_at,current_period_end,cancel_at_period_end,active_agent_ids)
      VALUES (@id,@name,@email,@plan,@status,@agents_active,@monthly_spend,@joined_at,@isp,
              @stripe_customer_id,@stripe_subscription_id,@stripe_checkout_session_id,
              @billing_status,@billing_invited_at,@current_period_end,@cancel_at_period_end,@active_agent_ids)
    `).run(sub);
    res.status(201).json(subscriberFromRow(d.prepare('SELECT * FROM subscribers WHERE id=?').get(sub.id)));
  });

  router.patch('/:id', (req, res) => {
    const d = db();
    const row = d.prepare('SELECT * FROM subscribers WHERE id=?').get(req.params.id);
    if (!row) return res.status(404).json({ error: 'Not found' });
    const b = req.body;
    const fields = ['name','email','plan','status','isp','billing_status'];
    const setClauses = [];
    const params = { id: req.params.id };
    const keyMap = { name:'name',email:'email',plan:'plan',status:'status',isp:'isp',billingStatus:'billing_status' };
    for (const [jsKey, dbKey] of Object.entries(keyMap)) {
      if (b[jsKey] !== undefined) { setClauses.push(`${dbKey}=@${dbKey}`); params[dbKey] = b[jsKey]; }
    }
    if (b.activeAgentIds !== undefined) { setClauses.push('active_agent_ids=@active_agent_ids'); params.active_agent_ids = JSON.stringify(b.activeAgentIds); }
    if (b.stripeCustomerId !== undefined) { setClauses.push('stripe_customer_id=@stripe_customer_id'); params.stripe_customer_id = b.stripeCustomerId; }
    if (b.stripeSubscriptionId !== undefined) { setClauses.push('stripe_subscription_id=@stripe_subscription_id'); params.stripe_subscription_id = b.stripeSubscriptionId; }
    if (b.cancelAtPeriodEnd !== undefined) { setClauses.push('cancel_at_period_end=@cancel_at_period_end'); params.cancel_at_period_end = b.cancelAtPeriodEnd ? 1 : 0; }
    if (b.currentPeriodEnd !== undefined) { setClauses.push('current_period_end=@current_period_end'); params.current_period_end = b.currentPeriodEnd; }
    if (setClauses.length > 0) {
      d.prepare(`UPDATE subscribers SET ${setClauses.join(',')} WHERE id=@id`).run(params);
    }
    res.json(subscriberFromRow(d.prepare('SELECT * FROM subscribers WHERE id=?').get(req.params.id)));
  });

  router.delete('/:id', (req, res) => {
    const info = db().prepare('DELETE FROM subscribers WHERE id=?').run(req.params.id);
    if (info.changes === 0) return res.status(404).json({ error: 'Not found' });
    res.json({ ok: true });
  });

  // ── Subscriber Stripe billing ─────────────────────────────────────────────

  router.post('/:id/billing/checkout', async (req, res) => {
    const stripe = getStripe();
    if (!stripe) return res.status(400).json({ error: 'Stripe not configured' });
    const d = db();
    const row = d.prepare('SELECT * FROM subscribers WHERE id=?').get(req.params.id);
    if (!row) return res.status(404).json({ error: 'Subscriber not found' });
    const sub = subscriberFromRow(row);
    const plan = SUBSCRIBER_PLANS[sub.plan];
    if (!plan) return res.status(400).json({ error: 'Unknown plan: ' + sub.plan });
    const { successUrl, cancelUrl } = req.body;
    try {
      const params = {
        mode: 'subscription',
        line_items: [{ price: plan.priceId, quantity: 1 }],
        customer_email: sub.stripeCustomerId ? undefined : sub.email,
        success_url: successUrl || portalUrl('/isp-portal/#/subscribers?billing=success'),
        cancel_url: cancelUrl || portalUrl('/isp-portal/#/subscribers?billing=canceled'),
        metadata: { subscriberId: sub.id, plan: sub.plan, ispName: loadSettings().ispName||'EtherOS' },
      };
      if (sub.stripeCustomerId) params.customer = sub.stripeCustomerId;
      const session = await stripe.checkout.sessions.create(params);
      d.prepare(`UPDATE subscribers SET billing_status='invited',billing_invited_at=?,stripe_checkout_session_id=? WHERE id=?`)
        .run(new Date().toISOString(), session.id, sub.id);
      res.json({ checkoutUrl: session.url, sessionId: session.id, subscriber: subscriberFromRow(d.prepare('SELECT * FROM subscribers WHERE id=?').get(sub.id)) });
    } catch (err) { res.status(500).json({ error: err.message }); }
  });

  router.post('/:id/billing/portal', async (req, res) => {
    const stripe = getStripe();
    if (!stripe) return res.status(400).json({ error: 'Stripe not configured' });
    const row = db().prepare('SELECT * FROM subscribers WHERE id=?').get(req.params.id);
    if (!row) return res.status(404).json({ error: 'Subscriber not found' });
    const sub = subscriberFromRow(row);
    if (!sub.stripeCustomerId) return res.status(400).json({ error: 'No Stripe customer for this subscriber' });
    try {
      const session = await stripe.billingPortal.sessions.create({
        customer: sub.stripeCustomerId,
        return_url: req.body.returnUrl || portalUrl('/isp-portal/#/subscribers'),
      });
      res.json({ portalUrl: session.url });
    } catch (err) { res.status(500).json({ error: err.message }); }
  });

  router.get('/:id/billing', async (req, res) => {
    const d = db();
    const row = d.prepare('SELECT * FROM subscribers WHERE id=?').get(req.params.id);
    if (!row) return res.status(404).json({ error: 'Subscriber not found' });
    const sub = subscriberFromRow(row);
    const stripe = getStripe();
    if (stripe && sub.stripeSubscriptionId) {
      try {
        const stripeSub = await stripe.subscriptions.retrieve(sub.stripeSubscriptionId);
        const newStatus = stripeSub.status === 'active' ? 'active'
          : stripeSub.status === 'past_due' ? 'past_due'
          : stripeSub.status === 'canceled' ? 'canceled' : sub.billingStatus;
        d.prepare(`UPDATE subscribers SET billing_status=?,current_period_end=?,cancel_at_period_end=? WHERE id=?`)
          .run(newStatus, new Date(stripeSub.current_period_end * 1000).toISOString(), stripeSub.cancel_at_period_end ? 1 : 0, sub.id);
        return res.json(subscriberFromRow(d.prepare('SELECT * FROM subscribers WHERE id=?').get(sub.id)));
      } catch {}
    }
    res.json(sub);
  });

  router.post('/:id/billing/upgrade', async (req, res) => {
    const stripe = getStripe();
    if (!stripe) return res.status(400).json({ error: 'Stripe not configured' });
    const d = db();
    const row = d.prepare('SELECT * FROM subscribers WHERE id=?').get(req.params.id);
    if (!row) return res.status(404).json({ error: 'Subscriber not found' });
    const sub = subscriberFromRow(row);
    const auth = req.headers.authorization || '';
    const token = auth.startsWith('Bearer ') ? auth.slice(7) : null;
    const settings = loadSettings();
    const isAdmin = req.headers['x-admin-token'] === settings.adminToken;
    const isSubscriber = token && parseToken(token) === sub.id;
    if (!isAdmin && !isSubscriber) return res.status(403).json({ error: 'Forbidden' });
    const { newPlan, successUrl, cancelUrl } = req.body;
    const plan = SUBSCRIBER_PLANS[newPlan];
    if (!plan) return res.status(400).json({ error: 'Invalid plan: ' + newPlan });
    try {
      if (sub.stripeSubscriptionId) {
        const ss = await stripe.subscriptions.retrieve(sub.stripeSubscriptionId);
        const itemId = ss.items.data[0]?.id;
        if (itemId) {
          await stripe.subscriptions.update(sub.stripeSubscriptionId, {
            items: [{ id: itemId, price: plan.priceId }],
            proration_behavior: 'create_prorations',
            metadata: { subscriberId: sub.id, plan: newPlan },
          });
          d.prepare(`UPDATE subscribers SET plan=?,billing_status='active' WHERE id=?`).run(newPlan, sub.id);
          return res.json({ ok: true, upgraded: true, plan: newPlan });
        }
      }
      const params = {
        mode: 'subscription',
        line_items: [{ price: plan.priceId, quantity: 1 }],
        customer_email: sub.stripeCustomerId ? undefined : sub.email,
        success_url: successUrl || portalUrl('/#/terminal?billing=success'),
        cancel_url: cancelUrl || portalUrl('/#/terminal?billing=canceled'),
        metadata: { subscriberId: sub.id, plan: newPlan },
      };
      if (sub.stripeCustomerId) params.customer = sub.stripeCustomerId;
      const session = await stripe.checkout.sessions.create(params);
      res.json({ checkoutUrl: session.url, sessionId: session.id });
    } catch (err) { res.status(500).json({ error: err.message }); }
  });

  router.post('/:id/billing/cancel', async (req, res) => {
    const stripe = getStripe();
    if (!stripe) return res.status(400).json({ error: 'Stripe not configured' });
    const d = db();
    const row = d.prepare('SELECT * FROM subscribers WHERE id=?').get(req.params.id);
    if (!row) return res.status(404).json({ error: 'Subscriber not found' });
    const sub = subscriberFromRow(row);
    const auth = req.headers.authorization || '';
    const token = auth.startsWith('Bearer ') ? auth.slice(7) : null;
    const settings = loadSettings();
    const isAdmin = req.headers['x-admin-token'] === settings.adminToken;
    const isSubscriber = token && parseToken(token) === sub.id;
    if (!isAdmin && !isSubscriber) return res.status(403).json({ error: 'Forbidden' });
    if (!sub.stripeSubscriptionId) return res.status(400).json({ error: 'No active subscription' });
    try {
      await stripe.subscriptions.update(sub.stripeSubscriptionId, { cancel_at_period_end: true });
      d.prepare('UPDATE subscribers SET cancel_at_period_end=1 WHERE id=?').run(sub.id);
      res.json({ ok: true, cancelAtPeriodEnd: true });
    } catch (err) { res.status(500).json({ error: err.message }); }
  });

  router.post('/:id/billing/reactivate', async (req, res) => {
    const stripe = getStripe();
    if (!stripe) return res.status(400).json({ error: 'Stripe not configured' });
    const d = db();
    const row = d.prepare('SELECT * FROM subscribers WHERE id=?').get(req.params.id);
    if (!row) return res.status(404).json({ error: 'Subscriber not found' });
    const sub = subscriberFromRow(row);
    const auth = req.headers.authorization || '';
    const token = auth.startsWith('Bearer ') ? auth.slice(7) : null;
    const settings = loadSettings();
    const isAdmin = req.headers['x-admin-token'] === settings.adminToken;
    const isSubscriber = token && parseToken(token) === sub.id;
    if (!isAdmin && !isSubscriber) return res.status(403).json({ error: 'Forbidden' });
    if (!sub.stripeSubscriptionId) return res.status(400).json({ error: 'No active subscription' });
    try {
      await stripe.subscriptions.update(sub.stripeSubscriptionId, { cancel_at_period_end: false });
      d.prepare('UPDATE subscribers SET cancel_at_period_end=0 WHERE id=?').run(sub.id);
      res.json({ ok: true, cancelAtPeriodEnd: false });
    } catch (err) { res.status(500).json({ error: err.message }); }
  });

  // ── Agent slots ───────────────────────────────────────────────────────────

  router.get('/:id/agents', (req, res) => {
    const d = db();
    const row = d.prepare('SELECT * FROM subscribers WHERE id=?').get(req.params.id);
    if (!row) return res.status(404).json({ error: 'Subscriber not found' });
    const sub = subscriberFromRow(row);
    const agents = d.prepare('SELECT * FROM agents WHERE id IN (' + (sub.activeAgentIds.map(() => '?').join(',') || 'NULL') + ')').all(...sub.activeAgentIds);
    res.json({ activeAgentIds: sub.activeAgentIds, agents, limit: PLAN_AGENT_LIMITS[sub.plan] || 3 });
  });

  router.post('/:id/agents/:agentId', (req, res) => {
    const d = db();
    const subRow = d.prepare('SELECT * FROM subscribers WHERE id=?').get(req.params.id);
    if (!subRow) return res.status(404).json({ error: 'Subscriber not found' });
    const agentRow = d.prepare('SELECT * FROM agents WHERE id=?').get(req.params.agentId);
    if (!agentRow) return res.status(404).json({ error: 'Agent not found' });
    if (!agentRow.is_enabled) return res.status(403).json({ error: 'Agent is not enabled by ISP' });
    const sub = subscriberFromRow(subRow);
    const limit = PLAN_AGENT_LIMITS[sub.plan] || 3;
    const activeIds = sub.activeAgentIds;
    if (activeIds.includes(req.params.agentId)) return res.status(409).json({ error: 'Agent already active for this subscriber' });
    if (activeIds.length >= limit) return res.status(403).json({ error: `Plan limit reached (${limit} agents max on ${sub.plan} plan)` });
    const newIds = [...activeIds, req.params.agentId];
    d.prepare('UPDATE subscribers SET active_agent_ids=?,agents_active=? WHERE id=?').run(JSON.stringify(newIds), newIds.length, sub.id);
    d.prepare('UPDATE agents SET activation_count=activation_count+1 WHERE id=?').run(req.params.agentId);
    const updated = subscriberFromRow(d.prepare('SELECT * FROM subscribers WHERE id=?').get(sub.id));
    res.json({ ok: true, subscriber: updated, activeAgentIds: updated.activeAgentIds });
  });

  router.delete('/:id/agents/:agentId', (req, res) => {
    const d = db();
    const subRow = d.prepare('SELECT * FROM subscribers WHERE id=?').get(req.params.id);
    if (!subRow) return res.status(404).json({ error: 'Subscriber not found' });
    const sub = subscriberFromRow(subRow);
    const newIds = sub.activeAgentIds.filter(id => id !== req.params.agentId);
    d.prepare('UPDATE subscribers SET active_agent_ids=?,agents_active=? WHERE id=?').run(JSON.stringify(newIds), newIds.length, sub.id);
    const updated = subscriberFromRow(d.prepare('SELECT * FROM subscribers WHERE id=?').get(sub.id));
    res.json({ ok: true, subscriber: updated, activeAgentIds: updated.activeAgentIds });
  });

  // ── Chat history ──────────────────────────────────────────────────────────

  function authToken(req, res) {
    const auth = (req.headers.authorization || '').replace('Bearer ', '');
    const id = parseToken(auth);
    if (!id) { res.status(401).json({ error: 'Invalid or expired token' }); return null; }
    if (id !== req.params.id) { res.status(403).json({ error: 'Forbidden' }); return null; }
    return id;
  }

  router.get('/:id/chats', (req, res) => {
    if (!authToken(req, res)) return;
    const d = db();
    const rows = d.prepare(`
      SELECT agent_id,role,content,timestamp
      FROM chat_messages WHERE subscriber_id=?
      ORDER BY timestamp ASC
    `).all(req.params.id);
    // Group by agent_id
    const map = {};
    for (const r of rows) {
      if (!map[r.agent_id]) map[r.agent_id] = [];
      map[r.agent_id].push(r);
    }
    const agentRows = d.prepare('SELECT * FROM agents').all();
    const agentMap = Object.fromEntries(agentRows.map(a => [a.id, a]));
    const conversations = Object.entries(map).map(([agentId, msgs]) => {
      const last = msgs[msgs.length - 1];
      const agent = agentMap[agentId];
      return {
        agentId, agentName: agent?.name || agentId, agentCategory: agent?.category || null,
        messageCount: msgs.length,
        lastMessage: { role: last.role, content: last.content.slice(0, 120), timestamp: last.timestamp },
      };
    }).filter(c => c.lastMessage)
      .sort((a, b) => new Date(b.lastMessage.timestamp) - new Date(a.lastMessage.timestamp));
    res.json({ conversations });
  });

  router.get('/:id/chats/:agentId', (req, res) => {
    if (!authToken(req, res)) return;
    const rows = db().prepare(`
      SELECT role,content,timestamp FROM chat_messages
      WHERE subscriber_id=? AND agent_id=?
      ORDER BY timestamp ASC
    `).all(req.params.id, req.params.agentId);
    const messages = rows.slice(-50);
    res.json({ messages, total: rows.length });
  });

  router.post('/:id/chats/:agentId', (req, res) => {
    if (!authToken(req, res)) return;
    const { role, content } = req.body || {};
    if (!role || !content) return res.status(400).json({ error: 'role and content required' });
    if (!['user', 'assistant'].includes(role)) return res.status(400).json({ error: 'role must be user or assistant' });
    const d = db();
    const ts = new Date().toISOString();
    d.prepare('INSERT INTO chat_messages (subscriber_id,agent_id,role,content,timestamp) VALUES (?,?,?,?,?)')
      .run(req.params.id, req.params.agentId, role, content, ts);
    // Trim to max 100 messages per agent/subscriber pair
    d.prepare(`DELETE FROM chat_messages WHERE id IN (
      SELECT id FROM chat_messages WHERE subscriber_id=? AND agent_id=?
      ORDER BY id ASC LIMIT MAX(0, (SELECT COUNT(*) FROM chat_messages WHERE subscriber_id=? AND agent_id=?) - 100)
    )`).run(req.params.id, req.params.agentId, req.params.id, req.params.agentId);
    const total = d.prepare('SELECT COUNT(*) as n FROM chat_messages WHERE subscriber_id=? AND agent_id=?').get(req.params.id, req.params.agentId).n;
    res.json({ ok: true, message: { role, content, timestamp: ts }, total });
  });

  router.delete('/:id/chats/:agentId', (req, res) => {
    if (!authToken(req, res)) return;
    db().prepare('DELETE FROM chat_messages WHERE subscriber_id=? AND agent_id=?').run(req.params.id, req.params.agentId);
    res.json({ ok: true });
  });

  // ── Blacknut cloud gaming ─────────────────────────────────────────────────

  const BLACKNUT_DEFAULT_API = 'https://api.blacknut.com';

  function planHasGaming(settings, plan) {
    const gamingPlans = Array.isArray(settings.blacknutGamingPlans) ? settings.blacknutGamingPlans : ['professional','charter'];
    return gamingPlans.includes(plan);
  }

  router.post('/:id/services/blacknut/session', async (req, res) => {
    const settings = loadSettings();
    if (!settings.blacknutEnabled) return res.status(403).json({ error: 'Gaming is not enabled for this ISP' });
    const row = db().prepare('SELECT * FROM subscribers WHERE id=?').get(req.params.id);
    if (!row) return res.status(404).json({ error: 'Subscriber not found' });
    const sub = subscriberFromRow(row);
    if (sub.status === 'suspended') return res.status(403).json({ error: 'Account suspended' });
    if (!planHasGaming(settings, sub.plan)) return res.status(403).json({ error: 'Gaming not included in your plan', plan: sub.plan });
    if (!settings.blacknutApiKey || !settings.blacknutPartnerId) {
      return res.json({ ok:true, stub:true, sessionId:'stub-'+Date.now(), launchUrl:'https://www.blacknut.com/en', expiresAt:new Date(Date.now()+4*3600_000).toISOString(), plan:sub.plan, message:'Blacknut API keys not yet configured' });
    }
    try {
      const apiBase = (settings.blacknutApiUrl || BLACKNUT_DEFAULT_API).replace(/\/$/, '');
      const r = await fetch(`${apiBase}/v1/sessions`, {
        method:'POST', headers:{'Content-Type':'application/json','X-Partner-Id':settings.blacknutPartnerId,'Authorization':`Bearer ${settings.blacknutApiKey}`},
        body: JSON.stringify({ partnerId:settings.blacknutPartnerId, externalUserId:sub.id, plan:sub.plan, userEmail:sub.email, displayName:sub.name }),
      });
      if (!r.ok) return res.status(502).json({ error:`Blacknut API error: ${r.status}`, detail: await r.text() });
      const data = await r.json();
      res.json({ ok:true, stub:false, sessionId:data.sessionId||data.id||data.session_id, launchUrl:data.launchUrl||data.url||data.sessionUrl, expiresAt:data.expiresAt||data.expires_at, plan:sub.plan });
    } catch (err) { res.status(502).json({ error:'Failed to reach Blacknut API', detail:String(err) }); }
  });

  router.get('/:id/services/blacknut/session/:sessionId', async (req, res) => {
    const settings = loadSettings();
    const { sessionId } = req.params;
    if (!settings.blacknutApiKey || !settings.blacknutPartnerId || sessionId.startsWith('stub-')) {
      return res.json({ sessionId, status:'active', stub:true });
    }
    try {
      const apiBase = (settings.blacknutApiUrl || BLACKNUT_DEFAULT_API).replace(/\/$/, '');
      const r = await fetch(`${apiBase}/v1/sessions/${sessionId}`, { headers:{'X-Partner-Id':settings.blacknutPartnerId,'Authorization':`Bearer ${settings.blacknutApiKey}`} });
      if (!r.ok) return res.status(r.status).json({ error:'Session not found or expired' });
      const data = await r.json();
      res.json({ sessionId, status:data.status||'active', expiresAt:data.expiresAt||data.expires_at, stub:false });
    } catch (err) { res.status(502).json({ error:'Failed to reach Blacknut API', detail:String(err) }); }
  });

  return router;
};
