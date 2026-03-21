'use strict';
/**
 * server.js — EtherOS ISP Portal Backend  (Sprint 4S — hardened)
 *
 * Route registration order matters in Express — public routes MUST be
 * registered before any auth-protected catch-all middleware.
 *
 * Order:
 *   1. Body parsers + CORS
 *   2. All PUBLIC routes (no auth required)
 *   3. All PROTECTED routes (auth required)
 *   4. Health + startup
 */

const express = require('express');
const cors    = require('cors');
const fs      = require('fs');
const path    = require('path');

const app = express();

// ── Raw body for Stripe webhook — MUST be before express.json() ──────────────
app.use('/api/billing/webhook', express.raw({ type: 'application/json' }));
app.use(express.json());
app.use(cors({ origin: '*' }));

// ── Multi-tenancy ─────────────────────────────────────────────────────────────
const TENANT_SLUG = (process.env.TENANT_SLUG || '').replace(/[^a-z0-9-]/g, '') || null;
const DATA_DIR    = TENANT_SLUG ? `/app/data/${TENANT_SLUG}` : '/app/data';

// ── Domain helpers ────────────────────────────────────────────────────────────
const SETTINGS_FILE = `${DATA_DIR}/isp-settings.json`;

function getPortalDomain() {
  try {
    const s = JSON.parse(fs.readFileSync(SETTINGS_FILE, 'utf8'));
    if (s.domain) return s.domain.replace(/\/$/, '');
  } catch {}
  return (process.env.TENANT_DOMAIN || 'edge.etheros.ai').replace(/\/$/, '');
}
function portalUrl(p = '') { return `https://${getPortalDomain()}${p}`; }
const EDGE_API = `https://${(process.env.TENANT_DOMAIN || 'edge.etheros.ai').replace(/\/$/, '')}/api`;

// ── Settings helpers ──────────────────────────────────────────────────────────
function loadSettings() {
  try { return JSON.parse(fs.readFileSync(SETTINGS_FILE, 'utf8')); }
  catch { return {}; }
}
function saveSettings(s) {
  fs.mkdirSync(path.dirname(SETTINGS_FILE), { recursive: true });
  fs.writeFileSync(SETTINGS_FILE, JSON.stringify(s, null, 2));
}
function getStripe() {
  // Prefer environment variable (allows live/test switching without UI change)
  const envKey = (process.env.STRIPE_SECRET_KEY || '').trim();
  const s = loadSettings();
  const key = envKey || (s.stripeKey || '').trim();
  if (!key) return null;
  try {
    const Stripe = require('stripe');
    return new Stripe(key, { apiVersion: '2024-12-18.acacia' });
  } catch { return null; }
}

// ── Subscriber token helpers ──────────────────────────────────────────────────
function makeToken(subscriberId) {
  return Buffer.from(`${subscriberId}.${Date.now()}`).toString('base64url');
}
function parseToken(token) {
  try {
    const decoded = Buffer.from(token, 'base64url').toString('utf8');
    const [subscriberId, ts] = decoded.split('.');
    const age = Date.now() - parseInt(ts, 10);
    if (!subscriberId || age > 8 * 60 * 60 * 1000) return null;
    return subscriberId;
  } catch { return null; }
}

// ── Shared helpers bundle ─────────────────────────────────────────────────────
const shared = {
  DATA_DIR, TENANT_SLUG, EDGE_API,
  loadSettings, saveSettings, getStripe,
  portalUrl, getPortalDomain,
  makeToken, parseToken,
};

// ── Auth + rate-limit middleware ──────────────────────────────────────────────
const { createAdminRouter, adminSessions, handleAdminLogin, handleAdminLogout } = require('./routes/admin');
const { requireAdmin, rateLimiter }        = require('./routes/middleware');
const auth = requireAdmin(adminSessions, loadSettings);

// ── Instantiate all routers ───────────────────────────────────────────────────
const terminalsRouter   = require('./routes/terminals')(DATA_DIR);
const subscribersRouter = require('./routes/subscribers')(DATA_DIR, loadSettings, getStripe, portalUrl);
const agentsRouter      = require('./routes/agents')(DATA_DIR);
const marketingRouter   = require('./routes/marketing')(DATA_DIR, loadSettings);
const acquisitionRouter = require('./routes/acquisition')(DATA_DIR, loadSettings);
const billingRouter     = require('./routes/billing')(DATA_DIR, loadSettings, getStripe, portalUrl);
const adminRouter       = createAdminRouter(shared);
const { createDashboardRouter } = require('./routes/dashboard');
const dashboardRouter   = createDashboardRouter(shared);
const { createChatRouter } = require('./routes/chat');
const chatRouter        = createChatRouter(shared);

// ════════════════════════════════════════════════════════════════════════════
// ── SECTION 1: PUBLIC routes — no auth required ──────────────────────────────
// ════════════════════════════════════════════════════════════════════════════

// Health
app.get('/health', (req, res) => {
  const s = loadSettings();
  res.json({ status: 'ok', service: 'isp-portal-backend', version: '2.0.0-4s',
    tenant: TENANT_SLUG || 'default', ispName: s.ispName || null,
    domain: s.domain || getPortalDomain(), ts: new Date().toISOString() });
});

// Admin auth (login/logout — can't gate login behind auth)
app.post('/api/admin/login',  rateLimiter(60_000, 10), handleAdminLogin(loadSettings));
app.post('/api/admin/logout', handleAdminLogout());

// Terminal kiosk boot endpoints — inline handlers so no path-stripping issues
app.get('/api/tenant', (req, res) => {
  const s = loadSettings();
  const name = s.ispName || 'EtherOS';
  res.json({
    slug: TENANT_SLUG || 'default', name,
    initials: name.split(' ').map(w => w[0]).join('').slice(0, 2).toUpperCase(),
    domain: s.domain || getPortalDomain(),
    accentColor: s.accentColor || '#00C2CB',
    logoUrl: s.logoUrl || null,
  });
});

app.get('/api/terminal/config', (req, res) => {
  const s = loadSettings();
  const gamingPlans = Array.isArray(s.blacknutGamingPlans) ? s.blacknutGamingPlans : ['professional', 'charter'];
  res.json({
    ispName: s.ispName || 'EtherOS', accentColor: s.accentColor || '#00C2CB',
    logoUrl: s.logoUrl || null, welcomeTitle: s.terminalWelcomeTitle || null,
    welcomeBody: s.terminalWelcomeBody || null, supportPhone: s.supportPhone || null,
    supportEmail: s.supportEmail || null, blacknutEnabled: !!s.blacknutEnabled,
    blacknutGamingPlans: gamingPlans,
  });
});

app.get('/api/isp-config', (req, res) => {
  const configDir = '/opt/etheros-edge/isp-config';
  try {
    const configs = fs.readdirSync(configDir).filter(f => f.endsWith('.json'))
      .map(f => { try { return JSON.parse(fs.readFileSync(path.join(configDir, f), 'utf8')); } catch { return null; } })
      .filter(Boolean);
    res.json(configs);
  } catch {
    const s = loadSettings();
    res.json([{ slug: TENANT_SLUG || 'etheros-default', name: s.ispName || 'EtherOS AI', domain: s.domain || getPortalDomain(), accent_color: s.accentColor || '#00C2CB' }]);
  }
});

// Blacknut status — terminal kiosk polls this
app.get('/api/services/blacknut/status', async (req, res) => {
  const s = loadSettings();
  if (!s.blacknutEnabled) return res.json({ enabled: false, status: 'disabled' });
  const apiKey = (s.blacknutApiKey || '').trim();
  if (!apiKey) return res.json({ enabled: true, status: 'no_key' });
  try {
    const r = await fetch('https://api.blacknut.com/v1/status', { headers: { Authorization: `Bearer ${apiKey}` }, signal: AbortSignal.timeout(8000) }).catch(() => null);
    if (!r) return res.json({ enabled: true, status: 'unreachable' });
    res.json({ enabled: true, status: r.ok ? 'ok' : 'error', httpStatus: r.status, ...await r.json().catch(() => ({})) });
  } catch (err) { res.json({ enabled: true, status: 'error', error: String(err) }); }
});

// Subscriber self-signup (public) — inline to avoid path stripping
const { sendPinWelcomeEmail, sendPinRecoveryEmail } = require('./routes/email');

app.post('/api/subscribers/signup', rateLimiter(60_000, 10), async (req, res) => {
  const { name, email, plan = 'personal', successUrl, cancelUrl } = req.body || {};
  if (!name || !email) return res.status(400).json({ error: 'name and email are required' });
  const SUBSCRIBER_PLANS = {
    personal:     { name: 'Personal',     priceMonthly: 1499, priceId: 'price_1TBPB5ERnCKuXiJaJSsWJBTw' },
    professional: { name: 'Professional', priceMonthly: 3999, priceId: 'price_1TBPCzERnCKuXiJagZEPZAVk' },
    charter:      { name: 'Charter',      priceMonthly: 9999, priceId: 'price_1TBPCzERnCKuXiJaB8DWJ84N' },
  };
  if (!SUBSCRIBER_PLANS[plan]) return res.status(400).json({ error: `Unknown plan: ${plan}` });
  const { getDb, subscriberFromRow } = require('./db');
  const { randomUUID, createHash } = require('crypto');
  const db = getDb(DATA_DIR);
  const existing = db.prepare('SELECT id FROM subscribers WHERE email=?').get(email);
  if (existing) return res.status(409).json({ error: 'An account with this email already exists' });
  const planInfo = SUBSCRIBER_PLANS[plan];
  const stripe = getStripe();
  function subscriberPin(sub) {
    return createHash('sha256').update(sub.id + sub.email).digest('hex').slice(-6).toUpperCase();
  }
  const subId = randomUUID();
  const sub = {
    id: subId, name, email, plan, status: 'active',
    agents_active: 0, monthly_spend: planInfo.priceMonthly / 100,
    joined_at: new Date().toISOString(), isp: null,
    stripe_customer_id: null, stripe_subscription_id: null,
    stripe_checkout_session_id: null, billing_status: 'none',
    billing_invited_at: null, current_period_end: null,
    cancel_at_period_end: 0, active_agent_ids: '[]',
  };
  db.prepare(`INSERT INTO subscribers
    (id,name,email,plan,status,agents_active,monthly_spend,joined_at,isp,
     stripe_customer_id,stripe_subscription_id,stripe_checkout_session_id,
     billing_status,billing_invited_at,current_period_end,cancel_at_period_end,active_agent_ids)
    VALUES (@id,@name,@email,@plan,@status,@agents_active,@monthly_spend,@joined_at,@isp,
            @stripe_customer_id,@stripe_subscription_id,@stripe_checkout_session_id,
            @billing_status,@billing_invited_at,@current_period_end,@cancel_at_period_end,@active_agent_ids)
  `).run(sub);
  if (planInfo.priceMonthly > 0 && stripe) {
    try {
      const session = await stripe.checkout.sessions.create({
        mode: 'subscription',
        line_items: [{ price: planInfo.priceId, quantity: 1 }],
        customer_email: email,
        success_url: successUrl || portalUrl(`/isp-portal/#/terminal?billing=success&session_id={CHECKOUT_SESSION_ID}`),
        cancel_url: cancelUrl || portalUrl(`/isp-portal/#/subscribe?billing=canceled`),
        metadata: { subscriberId: subId, plan, subscriberName: name },
      });
      db.prepare('UPDATE subscribers SET stripe_checkout_session_id=?,billing_status=? WHERE id=?')
        .run(session.id, 'invited', subId);
      const created = subscriberFromRow(db.prepare('SELECT * FROM subscribers WHERE id=?').get(subId));
      // No welcome email here — PIN email fires after checkout.session.completed webhook
      return res.status(201).json({ ok: true, requiresCheckout: true, checkoutUrl: session.url, subscriberId: subId, subscriber: created });
    } catch (err) { return res.status(500).json({ error: err.message }); }
  }
  // Free path (no Stripe) — send welcome + PIN email immediately
  const created = subscriberFromRow(db.prepare('SELECT * FROM subscribers WHERE id=?').get(subId));
  const pin = subscriberPin(created);
  const settings = loadSettings();
  sendPinWelcomeEmail({
    subscriber: created, pin,
    ispName: settings.ispName || 'EtherOS',
    terminalUrl: portalUrl('/isp-portal/#/terminal'),
    loadSettings,
  }).catch(() => {}); // fire-and-forget
  return res.status(201).json({ ok: true, requiresCheckout: false, subscriberId: subId, pin, subscriber: created });
});

// Stripe checkout result — MUST be before /:id routes to avoid param capture
// Public: returns PIN after Stripe redirect. Polls Stripe directly if webhook hasn't fired yet.
app.get('/api/subscribers/checkout-result', rateLimiter(60_000, 15), async (req, res) => {
  const { session_id } = req.query;
  if (!session_id) return res.status(400).json({ error: 'session_id required' });
  const { getDb, subscriberFromRow } = require('./db');
  const { createHash } = require('crypto');
  function subscriberPin(sub) {
    return createHash('sha256').update(sub.id + sub.email).digest('hex').slice(-6).toUpperCase();
  }
  const db = getDb(DATA_DIR);
  let row = db.prepare('SELECT * FROM subscribers WHERE stripe_checkout_session_id=?').get(session_id);
  const stripe = getStripe();
  if (stripe) {
    try {
      const sess = await stripe.checkout.sessions.retrieve(session_id);
      if (sess.metadata?.subscriberId) {
        row = db.prepare('SELECT * FROM subscribers WHERE id=?').get(sess.metadata.subscriberId) || row;
        if (sess.status === 'complete' && row) {
          db.prepare("UPDATE subscribers SET billing_status='active' WHERE id=? AND billing_status IN ('none','invited')")
            .run(row.id);
          row = db.prepare('SELECT * FROM subscribers WHERE id=?').get(row.id);
        }
      }
    } catch { /* non-fatal */ }
  }
  if (!row) return res.status(404).json({ ok: false, error: 'Checkout session not found' });
  const sub = subscriberFromRow(row);
  res.json({ ok: true, subscriberId: sub.id, name: sub.name, plan: sub.plan, billingStatus: sub.billingStatus, pin: subscriberPin(sub) });
});

// Subscriber billing summary (Bearer token — subscriber self-service)
app.get('/api/subscribers/:id/billing-summary', async (req, res) => {
  const auth = (req.headers.authorization || '').replace('Bearer ', '');
  const id = parseToken(auth);
  if (!id || id !== req.params.id) return res.status(401).json({ error: 'Invalid or expired session' });
  const { getDb, subscriberFromRow } = require('./db');
  const db = getDb(DATA_DIR);
  const row = db.prepare('SELECT * FROM subscribers WHERE id=?').get(req.params.id);
  if (!row) return res.status(404).json({ error: 'Subscriber not found' });
  const sub = subscriberFromRow(row);
  const SUBSCRIBER_PLANS = {
    personal:     { name: 'Personal',     priceMonthly: 1499 },
    professional: { name: 'Professional', priceMonthly: 3999 },
    charter:      { name: 'Charter',      priceMonthly: 9999 },
  };
  const planInfo = SUBSCRIBER_PLANS[sub.plan] || SUBSCRIBER_PLANS.personal;
  const allPlans = Object.entries(SUBSCRIBER_PLANS).map(([pid, p]) => ({ id: pid, name: p.name, priceMonthly: p.priceMonthly, current: pid === sub.plan }));
  let stripePortalUrl = null;
  const stripe = getStripe();
  if (stripe && sub.stripeCustomerId) {
    try {
      const session = await stripe.billingPortal.sessions.create({ customer: sub.stripeCustomerId, return_url: portalUrl('/isp-portal/#/terminal') });
      stripePortalUrl = session.url;
    } catch { /* non-fatal */ }
  }
  res.json({
    subscriberId: sub.id, name: sub.name, email: sub.email,
    plan: sub.plan, planName: planInfo.name, priceMonthly: planInfo.priceMonthly,
    billingStatus: sub.billingStatus, currentPeriodEnd: sub.currentPeriodEnd,
    cancelAtPeriodEnd: sub.cancelAtPeriodEnd, stripeCustomerId: sub.stripeCustomerId,
    hasActiveSubscription: sub.billingStatus === 'active',
    plans: allPlans, stripePortalUrl,
  });
});

// PIN recovery — public, rate-limited: send PIN to email on file
app.post('/api/subscribers/pin-recovery', rateLimiter(60_000, 5), async (req, res) => {
  const { email } = req.body || {};
  if (!email) return res.status(400).json({ error: 'email required' });
  const { getDb, subscriberFromRow } = require('./db');
  const { createHash } = require('crypto');
  const db = getDb(DATA_DIR);
  const row = db.prepare('SELECT * FROM subscribers WHERE email=?').get(email.trim().toLowerCase());
  // Always return success to prevent email enumeration
  if (!row) return res.json({ ok: true, sent: false });
  const sub = subscriberFromRow(row);
  const pin = createHash('sha256').update(sub.id + sub.email).digest('hex').slice(-6).toUpperCase();
  const settings = loadSettings();
  sendPinRecoveryEmail({
    subscriber: sub, pin,
    ispName: settings.ispName || 'EtherOS',
    terminalUrl: portalUrl('/isp-portal/#/terminal'),
    loadSettings,
  }).catch(() => {});
  return res.json({ ok: true, sent: true });
});

// Subscriber PIN auth (terminal login) — rate limited, inline to avoid path stripping
app.post('/api/subscribers/auth', rateLimiter(60_000, 20), (req, res) => {
  const { pin } = req.body || {};
  if (!pin) return res.status(400).json({ error: 'pin required' });
  const { getDb, subscriberFromRow } = require('./db');
  const db = getDb(DATA_DIR);
  const { createHash } = require('crypto');
  function subscriberPin(sub) {
    return createHash('sha256').update(sub.id + sub.email).digest('hex').slice(-6).toUpperCase();
  }
  const rows = db.prepare('SELECT * FROM subscribers').all();
  const row = rows.find(r => subscriberPin(subscriberFromRow(r)) === String(pin).toUpperCase());
  if (!row) return res.status(401).json({ error: 'PIN not recognised' });
  const sub = subscriberFromRow(row);
  if (sub.status === 'suspended') return res.status(403).json({ error: 'Account suspended' });
  const token = makeToken(sub.id);
  res.json({ ok: true, subscriberId: sub.id, name: sub.name, plan: sub.plan, token });
});

app.get('/api/subscribers/auth/pin/:id', (req, res) => {
  const { getDb, subscriberFromRow } = require('./db');
  const db = getDb(DATA_DIR);
  const { createHash } = require('crypto');
  function subscriberPin(sub) {
    return createHash('sha256').update(sub.id + sub.email).digest('hex').slice(-6).toUpperCase();
  }
  const row = db.prepare('SELECT * FROM subscribers WHERE id=?').get(req.params.id);
  if (!row) return res.status(404).json({ error: 'Not found' });
  res.json({ pin: subscriberPin(subscriberFromRow(row)) });
});

app.get('/api/subscribers/me', (req, res) => {
  const id = parseToken((req.headers.authorization || '').replace('Bearer ', ''));
  if (!id) return res.status(401).json({ error: 'Invalid or expired token' });
  const { getDb, subscriberFromRow } = require('./db');
  const db = getDb(DATA_DIR);
  const row = db.prepare('SELECT * FROM subscribers WHERE id=?').get(id);
  if (!row) return res.status(404).json({ error: 'Subscriber not found' });
  res.json(subscriberFromRow(row));
});

// POST /api/subscribers/:id/agents/:agentId — activate an agent for a subscriber
app.post('/api/subscribers/:id/agents/:agentId', (req, res) => {
  const token = (req.headers.authorization || '').replace('Bearer ', '');
  const { getDb, agentFromRow, subscriberFromRow } = require('./db');
  function parseSubscriberToken(t) {
    try {
      const [sid, ts] = Buffer.from(t, 'base64url').toString('utf8').split('.');
      if (!sid || Date.now() - parseInt(ts, 10) > 8 * 3600_000) return null;
      return sid;
    } catch { return null; }
  }
  const PLAN_AGENT_LIMITS = { personal: 3, professional: 10, charter: 999 };
  const tokenId = parseSubscriberToken(token);
  if (!tokenId || tokenId !== req.params.id) return res.status(401).json({ error: 'Invalid or expired session' });
  const db = getDb(DATA_DIR);
  const subRow = db.prepare('SELECT * FROM subscribers WHERE id=?').get(req.params.id);
  if (!subRow) return res.status(404).json({ error: 'Subscriber not found' });
  const sub = subscriberFromRow(subRow);
  const agentRow = db.prepare("SELECT * FROM agents WHERE id=? AND is_enabled=1 AND status='live'").get(req.params.agentId);
  if (!agentRow) return res.status(404).json({ error: 'Agent not found' });
  const agent = agentFromRow(agentRow);
  // Check plan limit
  const limit = PLAN_AGENT_LIMITS[sub.plan] || 3;
  const activeIds = [...sub.activeAgentIds];
  if (activeIds.includes(req.params.agentId)) return res.json({ ok: true, activeAgentIds: activeIds }); // already active
  if (activeIds.length >= limit) return res.status(402).json({ error: 'Agent slot limit reached', limitReached: true, limit });
  // Add-on billing check (stub — always allow in test mode)
  if (agent.pricingType === 'addon' && agent.priceMonthly > 0) {
    // Future: charge via Stripe. For now allow if plan is active.
    if (sub.billingStatus !== 'active') {
      return res.status(402).json({ requiresBilling: true, agentName: agent.name, priceMonthly: agent.priceMonthly });
    }
  }
  activeIds.push(req.params.agentId);
  db.prepare('UPDATE subscribers SET active_agent_ids=? WHERE id=?').run(JSON.stringify(activeIds), req.params.id);
  res.json({ ok: true, activeAgentIds: activeIds });
});

// DELETE /api/subscribers/:id/agents/:agentId — deactivate an agent for a subscriber
app.delete('/api/subscribers/:id/agents/:agentId', (req, res) => {
  const token = (req.headers.authorization || '').replace('Bearer ', '');
  const { getDb, subscriberFromRow } = require('./db');
  function parseSubscriberToken(t) {
    try {
      const [sid, ts] = Buffer.from(t, 'base64url').toString('utf8').split('.');
      if (!sid || Date.now() - parseInt(ts, 10) > 8 * 3600_000) return null;
      return sid;
    } catch { return null; }
  }
  const tokenId = parseSubscriberToken(token);
  if (!tokenId || tokenId !== req.params.id) return res.status(401).json({ error: 'Invalid or expired session' });
  const db = getDb(DATA_DIR);
  const subRow = db.prepare('SELECT * FROM subscribers WHERE id=?').get(req.params.id);
  if (!subRow) return res.status(404).json({ error: 'Subscriber not found' });
  const sub = subscriberFromRow(subRow);
  const activeIds = sub.activeAgentIds.filter(id => id !== req.params.agentId);
  db.prepare('UPDATE subscribers SET active_agent_ids=? WHERE id=?').run(JSON.stringify(activeIds), req.params.id);
  res.json({ ok: true, activeAgentIds: activeIds });
});

// Agent browse — terminal marketplace (inline to avoid path stripping)
app.get('/api/agents/browse', (req, res) => {
  const token = (req.headers.authorization || '').replace('Bearer ', '');
  const { getDb, agentFromRow, subscriberFromRow } = require('./db');
  const { Buffer } = require('buffer');
  function parseSubscriberToken(t) {
    try {
      const [id, ts] = Buffer.from(t, 'base64url').toString('utf8').split('.');
      if (!id || Date.now() - parseInt(ts, 10) > 8 * 3600_000) return null;
      return id;
    } catch { return null; }
  }
  const PLAN_AGENT_LIMITS = { personal: 3, professional: 10, charter: 999 };
  const subscriberId = parseSubscriberToken(token);
  if (!subscriberId) return res.status(401).json({ error: 'Invalid or expired session' });
  const db = getDb(DATA_DIR);
  const subRow = db.prepare('SELECT * FROM subscribers WHERE id=?').get(subscriberId);
  if (!subRow) return res.status(404).json({ error: 'Subscriber not found' });
  const sub = subscriberFromRow(subRow);
  const rows = db.prepare("SELECT * FROM agents WHERE is_enabled=1 AND status='live'").all();
  const activeIds = sub.activeAgentIds;
  const limit = PLAN_AGENT_LIMITS[sub.plan] || 3;
  res.json({
    agents: rows.map(r => ({ ...agentFromRow(r), activated: activeIds.includes(r.id) })),
    activeAgentIds: activeIds, limit,
    slotsUsed: activeIds.length, slotsRemaining: Math.max(0, limit - activeIds.length),
    plan: sub.plan,
  });
});

// Acquisition public — landing page render + lead capture (inline)
app.get('/api/acquisition/pages/:slug/render', (req, res) => {
  const { getDb, acqPageFromRow } = require('./db');
  const db = getDb(DATA_DIR);
  const row = db.prepare('SELECT * FROM acquisition_pages WHERE slug=? AND published=1').get(req.params.slug);
  if (!row) return res.status(404).json({ error: 'Page not found or not published' });
  db.prepare('UPDATE acquisition_pages SET views=views+1 WHERE slug=?').run(req.params.slug);
  const updated = db.prepare('SELECT * FROM acquisition_pages WHERE slug=?').get(req.params.slug);
  res.json(acqPageFromRow(updated));
});

app.post('/api/acquisition/leads', async (req, res) => {
  const { name, email, phone, company, message, pageSlug, leadType } = req.body;
  if (!name || !email || !pageSlug) return res.status(400).json({ error: 'name, email, pageSlug required' });
  const { getDb, acqPageFromRow, acqLeadFromRow } = require('./db');
  const { randomUUID } = require('crypto');
  const db = getDb(DATA_DIR);
  const now = new Date().toISOString();
  const lead = {
    id: randomUUID(), name, email, phone: phone||'', company: company||'',
    message: message||'', page_slug: pageSlug, lead_type: leadType||'general',
    status: 'new', created_at: now,
  };
  db.prepare(`INSERT INTO acquisition_leads
    (id,name,email,phone,company,message,page_slug,lead_type,status,created_at)
    VALUES (@id,@name,@email,@phone,@company,@message,@page_slug,@lead_type,@status,@created_at)
  `).run(lead);
  db.prepare('UPDATE acquisition_pages SET leads=leads+1 WHERE slug=?').run(pageSlug);
  res.status(201).json({ ok: true, id: lead.id });
});

// Billing public — Stripe webhook (app.use preserves path correctly for billingRouter)
app.use('/api/billing/webhook', billingRouter);

// Billing plans — inline to avoid path stripping
app.get('/api/billing/plans', (req, res) => {
  const STRIPE_PLANS = [
    { id:'starter',    name:'Starter',    priceMonthly:29900,  terminalLimit:25,   subscriberLimit:200,  features:['Up to 25 EtherOS terminals','Up to 200 active subscribers','All free marketplace agents','Basic analytics dashboard','Email support'],                                                                  stripePriceId:'price_1TBFYVERnCKuXiJafhCHg3I7', stripePriceIdTest:'price_1TBFYVERnCKuXiJafhCHg3I7' },
    { id:'growth',     name:'Growth',     priceMonthly:79900,  terminalLimit:100,  subscriberLimit:1000, features:['Up to 100 EtherOS terminals','Up to 1,000 active subscribers','All marketplace agents including premium','Full revenue analytics + export','Priority support + SLA','White-label branding'],     stripePriceId:'price_1TBFZEERnCKuXiJaCrEBy0JN', stripePriceIdTest:'price_1TBFZEERnCKuXiJaCrEBy0JN' },
    { id:'enterprise', name:'Enterprise', priceMonthly:199900, terminalLimit:9999, subscriberLimit:9999, features:['Unlimited EtherOS terminals','Unlimited active subscribers','All agents + first access to new releases','Custom agent development','Dedicated account manager','Custom integrations + API access'], stripePriceId:'price_1TBFZsERnCKuXiJaSteuC2TV', stripePriceIdTest:'price_1TBFZsERnCKuXiJaSteuC2TV' },
  ];
  res.json(STRIPE_PLANS);
});

// Chat stream — subscriber token auth enforced inside the router
app.use('/api/chat', chatRouter);

// ── Subscriber chat history — subscriber Bearer token auth (NOT admin auth) ──
// These must be declared BEFORE the admin-auth block below.
(function() {
  function parseSubToken(t) {
    try {
      const [id, ts] = Buffer.from(t, 'base64url').toString('utf8').split('.');
      if (!id || Date.now() - parseInt(ts, 10) > 8 * 3600_000) return null;
      return id;
    } catch { return null; }
  }
  function subAuth(req, res) {
    const token = (req.headers.authorization || '').replace('Bearer ', '');
    const id = parseSubToken(token);
    if (!id || id !== req.params.id) { res.status(401).json({ error: 'Invalid or expired session' }); return null; }
    return id;
  }

  // GET /api/subscribers/:id/chats — list recent conversations
  app.get('/api/subscribers/:id/chats', (req, res) => {
    if (!subAuth(req, res)) return;
    const { getDb, agentFromRow } = require('./db');
    const d = getDb(DATA_DIR);
    const rows = d.prepare('SELECT agent_id,role,content,timestamp FROM chat_messages WHERE subscriber_id=? ORDER BY timestamp ASC').all(req.params.id);
    const map = {};
    for (const r of rows) { if (!map[r.agent_id]) map[r.agent_id] = []; map[r.agent_id].push(r); }
    const agentRows = d.prepare('SELECT * FROM agents').all();
    const agentMap = Object.fromEntries(agentRows.map(a => [a.id, a]));
    const conversations = Object.entries(map).map(([agentId, msgs]) => {
      const last = msgs[msgs.length - 1];
      const agent = agentMap[agentId];
      return { agentId, agentName: agent?.name || agentId, agentCategory: agent?.category || null, messageCount: msgs.length, lastMessage: { role: last.role, content: last.content.slice(0, 120), timestamp: last.timestamp } };
    }).filter(c => c.lastMessage).sort((a, b) => new Date(b.lastMessage.timestamp) - new Date(a.lastMessage.timestamp));
    res.json({ conversations });
  });

  // GET /api/subscribers/:id/chats/:agentId — get messages for one agent
  app.get('/api/subscribers/:id/chats/:agentId', (req, res) => {
    if (!subAuth(req, res)) return;
    const { getDb } = require('./db');
    const rows = getDb(DATA_DIR).prepare('SELECT role,content,timestamp FROM chat_messages WHERE subscriber_id=? AND agent_id=? ORDER BY timestamp ASC').all(req.params.id, req.params.agentId);
    res.json({ messages: rows.slice(-50), total: rows.length });
  });

  // POST /api/subscribers/:id/chats/:agentId — save a message
  app.post('/api/subscribers/:id/chats/:agentId', (req, res) => {
    if (!subAuth(req, res)) return;
    const { role, content } = req.body || {};
    if (!role || !content) return res.status(400).json({ error: 'role and content required' });
    if (!['user', 'assistant'].includes(role)) return res.status(400).json({ error: 'role must be user or assistant' });
    const { getDb } = require('./db');
    const d = getDb(DATA_DIR);
    const ts = new Date().toISOString();
    d.prepare('INSERT INTO chat_messages (subscriber_id,agent_id,role,content,timestamp) VALUES (?,?,?,?,?)').run(req.params.id, req.params.agentId, role, content, ts);
    d.prepare('DELETE FROM chat_messages WHERE id IN (SELECT id FROM chat_messages WHERE subscriber_id=? AND agent_id=? ORDER BY id ASC LIMIT MAX(0,(SELECT COUNT(*) FROM chat_messages WHERE subscriber_id=? AND agent_id=?)-100))').run(req.params.id, req.params.agentId, req.params.id, req.params.agentId);
    const total = d.prepare('SELECT COUNT(*) as n FROM chat_messages WHERE subscriber_id=? AND agent_id=?').get(req.params.id, req.params.agentId).n;
    res.json({ ok: true, message: { role, content, timestamp: ts }, total });
  });

  // DELETE /api/subscribers/:id/chats/:agentId — clear history
  app.delete('/api/subscribers/:id/chats/:agentId', (req, res) => {
    if (!subAuth(req, res)) return;
    const { getDb } = require('./db');
    getDb(DATA_DIR).prepare('DELETE FROM chat_messages WHERE subscriber_id=? AND agent_id=?').run(req.params.id, req.params.agentId);
    res.json({ ok: true });
  });
})();

// ════════════════════════════════════════════════════════════════════════════
// ── SECTION 2: PROTECTED routes — admin token required ───────────────────────
// ════════════════════════════════════════════════════════════════════════════

app.use('/api/terminals',   auth, terminalsRouter);
app.use('/api/subscribers', auth, subscribersRouter);
app.use('/api/agents',      auth, agentsRouter);
app.use('/api/marketing',   auth, marketingRouter);
app.use('/api/acquisition', auth, acquisitionRouter);
app.use('/api/billing',     auth, billingRouter);
app.use('/api',             auth, dashboardRouter);   // /api/dashboard /api/server-stats /api/revenue
app.use('/api',             auth, adminRouter);       // /api/settings /api/admin/verify /api/edge-* etc.

// ── Startup: force JSON→SQLite migration ─────────────────────────────────────
(function runMigration() {
  try {
    const { getDb, migrateFromJson } = require('./db');
    const db = getDb(DATA_DIR);
    if (!db) { console.log('[migration] shim mode — better-sqlite3 unavailable'); return; }
    const result = migrateFromJson(db, DATA_DIR);
    if (result.skipped) console.log('[migration] already migrated — skipping');
    else console.log('[migration] JSON→SQLite complete:', JSON.stringify(result));
  } catch (err) {
    console.error('[migration] failed (non-fatal):', err.message);
  }
})();

// ── Start ─────────────────────────────────────────────────────────────────────
const PORT = process.env.PORT || 3010;
app.listen(PORT, () => {
  console.log(`[isp-portal] listening on :${PORT}  tenant=${TENANT_SLUG || 'default'}  version=4S`);
});
