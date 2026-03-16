'use strict';
const express = require('express');
const cors    = require('cors');
const { randomUUID } = require('crypto');

const app = express();

// Raw body for Stripe webhooks (must be before express.json())
app.use('/api/billing/webhook', express.raw({ type: 'application/json' }));
app.use(express.json());
app.use(cors({ origin: '*' }));

const EDGE_API = 'https://edge.etheros.ai/api';
const SETTINGS_FILE = '/app/data/isp-settings.json';
const fs   = require('fs');
const path = require('path');

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
  const s = loadSettings();
  const key = (s.stripeKey || '').trim();
  if (!key) return null;
  try {
    const Stripe = require('stripe');
    return new Stripe(key, { apiVersion: '2024-12-18.acacia' });
  } catch { return null; }
}

// ── Billing state (in-memory, synced from Stripe) ────────────────────────────
const BILLING_FILE = '/app/data/billing-state.json';
function loadBillingState() {
  try { return JSON.parse(fs.readFileSync(BILLING_FILE, 'utf8')); } catch { return {}; }
}
function saveBillingState(s) {
  try { fs.mkdirSync(path.dirname(BILLING_FILE), { recursive: true }); fs.writeFileSync(BILLING_FILE, JSON.stringify(s, null, 2)); } catch {}
}
let billingState = {
  customerId: null, subscriptionId: null, planId: null, status: 'none',
  currentPeriodEnd: null, cancelAtPeriodEnd: false, trialEnd: null,
  paymentMethodLast4: null, paymentMethodBrand: null,
  ...loadBillingState(),
};

const STRIPE_PLANS = [
  {
    id: 'starter', name: 'Starter',
    description: 'Perfect for rural ISPs getting started with AI-powered terminals.',
    priceMonthly: 29900, terminalLimit: 25, subscriberLimit: 200,
    features: [
      'Up to 25 EtherOS terminals', 'Up to 200 active subscribers',
      'All free marketplace agents', 'Basic analytics dashboard', 'Email support',
    ],
    stripePriceId: 'price_1TBFYVERnCKuXiJafhCHg3I7', stripePriceIdTest: 'price_1TBFYVERnCKuXiJafhCHg3I7',
  },
  {
    id: 'growth', name: 'Growth',
    description: 'For expanding ISPs with growing subscriber bases and premium agents.',
    priceMonthly: 79900, terminalLimit: 100, subscriberLimit: 1000,
    features: [
      'Up to 100 EtherOS terminals', 'Up to 1,000 active subscribers',
      'All marketplace agents including premium', 'Full revenue analytics + export',
      'Priority support + SLA', 'White-label branding',
    ],
    stripePriceId: 'price_1TBFZEERnCKuXiJaCrEBy0JN', stripePriceIdTest: 'price_1TBFZEERnCKuXiJaCrEBy0JN',
  },
  {
    id: 'enterprise', name: 'Enterprise',
    description: 'Unlimited scale for large regional ISPs and multi-state operators.',
    priceMonthly: 199900, terminalLimit: 9999, subscriberLimit: 9999,
    features: [
      'Unlimited EtherOS terminals', 'Unlimited active subscribers',
      'All agents + first access to new releases', 'Custom agent development',
      'Dedicated account manager', 'Custom integrations + API access',
    ],
    stripePriceId: 'price_1TBFZsERnCKuXiJaSteuC2TV', stripePriceIdTest: 'price_1TBFZsERnCKuXiJaSteuC2TV',
  },
];

async function syncSubscription(stripe, subscriptionId) {
  const sub = await stripe.subscriptions.retrieve(subscriptionId, {
    expand: ['default_payment_method', 'items.data.price'],
  });
  const priceId = sub.items.data[0]?.price?.id;
  const plan = STRIPE_PLANS.find(p => p.stripePriceId === priceId || p.stripePriceIdTest === priceId);
  billingState = {
    ...billingState,
    subscriptionId: sub.id,
    planId: plan?.id || null,
    status: sub.status,
    currentPeriodEnd: new Date(sub.current_period_end * 1000).toISOString(),
    cancelAtPeriodEnd: sub.cancel_at_period_end,
    trialEnd: sub.trial_end ? new Date(sub.trial_end * 1000).toISOString() : null,
    paymentMethodLast4: sub.default_payment_method?.card?.last4 || null,
    paymentMethodBrand: sub.default_payment_method?.card?.brand || null,
  };
}

async function fetchInvoices(stripe, customerId) {
  try {
    const list = await stripe.invoices.list({ customer: customerId, limit: 12 });
    return list.data.map(inv => ({
      id: inv.id,
      date: new Date(inv.created * 1000).toISOString(),
      amount: inv.amount_paid || inv.amount_due,
      status: inv.status,
      pdfUrl: inv.invoice_pdf,
      hostedUrl: inv.hosted_invoice_url,
    }));
  } catch { return []; }
}

// ── GET /api/billing ──────────────────────────────────────────────────────────
app.get('/api/billing', async (req, res) => {
  const stripe = getStripe();
  if (!stripe) {
    return res.json({ ...billingState, status: 'none', customerId: null, invoices: [] });
  }
  try {
    if (billingState.subscriptionId) await syncSubscription(stripe, billingState.subscriptionId);
    const invoices = billingState.customerId ? await fetchInvoices(stripe, billingState.customerId) : [];
    res.json({ ...billingState, invoices });
  } catch (err) {
    res.status(500).json({ error: String(err) });
  }
});

// ── GET /api/billing/plans ────────────────────────────────────────────────────
app.get('/api/billing/plans', (req, res) => {
  res.json(STRIPE_PLANS);
});

// ── POST /api/billing/checkout ────────────────────────────────────────────────
app.post('/api/billing/checkout', async (req, res) => {
  const stripe = getStripe();
  if (!stripe) return res.status(400).json({ error: 'Stripe not configured. Add your Stripe secret key in Settings.' });
  const { planId, successUrl, cancelUrl } = req.body;
  const plan = STRIPE_PLANS.find(p => p.id === planId);
  if (!plan) return res.status(400).json({ error: 'Unknown plan' });

  const settings = loadSettings();
  const isTest = settings.stripeKey?.startsWith('sk_test_');
  const priceId = isTest ? plan.stripePriceIdTest : plan.stripePriceId;

  try {
    const params = {
      mode: 'subscription',
      line_items: [{ price: priceId, quantity: 1 }],
      subscription_data: { trial_period_days: 14 },
      success_url: (() => {
        const base = successUrl || 'https://edge.etheros.ai/isp-portal/#/billing?status=success';
        return base + (base.includes('?') ? '&' : '?') + 'session_id={CHECKOUT_SESSION_ID}';
      })(),
      cancel_url: cancelUrl || 'https://edge.etheros.ai/isp-portal/#/billing?status=canceled',
    };
    if (billingState.customerId) params.customer = billingState.customerId;
    const session = await stripe.checkout.sessions.create(params);
    if (!billingState.customerId && session.customer) {
      billingState.customerId = session.customer;
      saveBillingState(billingState);
    }
    res.json({ url: session.url });
  } catch (err) {
    res.status(500).json({ error: String(err) });
  }
});

// ── GET /api/billing/sync-session ────────────────────────────────────────────
app.get('/api/billing/sync-session', async (req, res) => {
  const stripe = getStripe();
  if (!stripe) return res.json({ ok: false });
  const { session_id } = req.query;
  if (!session_id) return res.json({ ok: false, error: 'No session_id' });
  try {
    const session = await stripe.checkout.sessions.retrieve(session_id, {
      expand: ['subscription', 'customer']
    });
    if (session.customer) {
      billingState.customerId = typeof session.customer === 'string' ? session.customer : session.customer.id;
    }
    if (session.subscription) {
      const sub = typeof session.subscription === 'string'
        ? await stripe.subscriptions.retrieve(session.subscription)
        : session.subscription;
      const priceId = sub.items?.data?.[0]?.price?.id;
      const plan = STRIPE_PLANS.find(p => p.stripePriceId === priceId || p.stripePriceIdTest === priceId);
      billingState.subscriptionId = sub.id;
      billingState.planId = plan?.id ?? null;
      billingState.status = sub.status;
      billingState.currentPeriodEnd = new Date(sub.current_period_end * 1000).toISOString();
      billingState.trialEnd = sub.trial_end ? new Date(sub.trial_end * 1000).toISOString() : null;
      billingState.cancelAtPeriodEnd = sub.cancel_at_period_end;
    }
    saveBillingState(billingState);
    res.json({ ok: true, status: billingState.status, planId: billingState.planId });
  } catch (err) {
    res.json({ ok: false, error: String(err) });
  }
});

// ── POST /api/billing/portal ──────────────────────────────────────────────────
app.post('/api/billing/portal', async (req, res) => {
  const stripe = getStripe();
  if (!stripe) return res.status(400).json({ error: 'Stripe not configured' });
  if (!billingState.customerId) return res.status(400).json({ error: 'No active subscription' });
  const { returnUrl } = req.body;
  try {
    const session = await stripe.billingPortal.sessions.create({
      customer: billingState.customerId,
      return_url: returnUrl || 'https://edge.etheros.ai/isp-portal/#/billing',
    });
    res.json({ url: session.url });
  } catch (err) {
    res.status(500).json({ error: String(err) });
  }
});

// ── POST /api/billing/webhook ─────────────────────────────────────────────────
app.post('/api/billing/webhook', async (req, res) => {
  const stripe = getStripe();
  if (!stripe) return res.status(400).json({ error: 'Stripe not configured' });
  const settings = loadSettings();
  const sig = req.headers['stripe-signature'];
  const secret = settings.stripeWebhookSecret?.trim();
  let event;
  try {
    event = secret
      ? stripe.webhooks.constructEvent(req.body, sig, secret)
      : JSON.parse(req.body.toString());
  } catch (err) {
    return res.status(400).json({ error: 'Webhook signature verification failed' });
  }
  try {
    switch (event.type) {
      case 'customer.subscription.created':
      case 'customer.subscription.updated':
      case 'customer.subscription.deleted':
        if (event.data.object.id === billingState.subscriptionId || !billingState.subscriptionId) {
          billingState.subscriptionId = event.data.object.id;
          billingState.customerId = event.data.object.customer;
          await syncSubscription(stripe, event.data.object.id);
        }
        break;
      case 'checkout.session.completed':
        const sess = event.data.object;
        if (sess.subscription) {
          billingState.customerId = sess.customer;
        saveBillingState(billingState);
          billingState.subscriptionId = sess.subscription;
          await syncSubscription(stripe, sess.subscription);
        }
        break;
    }
    res.json({ received: true });
  } catch (err) {
    console.error('Webhook handler error:', err);
    res.status(500).json({ error: String(err) });
  }
});

// ── GET/POST /api/settings ────────────────────────────────────────────────────
app.get('/api/settings', (req, res) => {
  const s = loadSettings();
  // Mask stripe key
  if (s.stripeKey) s.stripeKey = s.stripeKey.substring(0, 8) + '••••••••';
  res.json(s);
});

app.post('/api/settings', (req, res) => {
  const existing = loadSettings();
  const update = { ...existing, ...req.body };
  // If masking detected, keep original key
  if ((update.stripeKey || '').includes('••••••••')) {
    update.stripeKey = existing.stripeKey;
  }
  saveSettings(update);
  res.json({ ok: true });
});


// ── PATCH /api/settings ───────────────────────────────────────────────────────
app.patch('/api/settings', (req, res) => {
  const existing = loadSettings();
  const update = { ...existing, ...req.body };
  if ((update.stripeKey || '').includes('••••')) {
    update.stripeKey = existing.stripeKey;
  }
  saveSettings(update);
  res.json({ ok: true });
});

// ── GET /api/settings/stripe-key-test ────────────────────────────────────────
app.get('/api/settings/stripe-key-test', async (req, res) => {
  const stripe = getStripe();
  if (!stripe) return res.json({ ok: false, error: 'No Stripe key configured' });
  try {
    await stripe.balance.retrieve();
    const s = loadSettings();
    const isTest = s.stripeKey?.startsWith('sk_test_');
    res.json({ ok: true, mode: isTest ? 'test' : 'live' });
  } catch (err) {
    res.json({ ok: false, error: String(err) });
  }
});

// ── Edge status ───────────────────────────────────────────────────────────────
app.get('/api/edge-status', async (req, res) => {
  try {
    // Query Ollama directly (same VPS) instead of external round-trip
    const tagsRes = await fetch('http://ollama:11434/api/tags', { signal: AbortSignal.timeout(5000) }).catch(() => null);
    const health = tagsRes?.ok ? { status: 'ok' } : null;
    const tagsData = tagsRes?.ok ? await tagsRes.json().catch(() => null) : null;
    const models = (tagsData?.models || []).map(m => m.name || m.id).filter(Boolean);
    res.json({
      edgeOnline: !!health, health, models,
      ollamaOnline: models.length > 0, checkedAt: new Date().toISOString(),
      edgeUrl: 'https://edge.etheros.ai',
    });
  } catch (err) {
    res.json({ edgeOnline: false, models: [], ollamaOnline: false, error: String(err), checkedAt: new Date().toISOString() });
  }
});

// ── Edge chat proxy ───────────────────────────────────────────────────────────
app.post('/api/edge-chat', async (req, res) => {
  const { model = 'qwen2:0.5b', messages = [] } = req.body;
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
    res.json(await upstream.json());
  } catch (err) {
    res.status(502).json({ error: String(err) });
  }
});

// ── ISP config ────────────────────────────────────────────────────────────────
app.get('/api/isp-config', (req, res) => {
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
app.get('/health', (req, res) => res.json({ status: 'ok', service: 'isp-portal-backend', version: '1.2.0-stripe', ts: new Date().toISOString() }));

const PORT = process.env.PORT || 3010;


// ── JSON file storage helpers ─────────────────────────────────────────────────
const TERMINALS_FILE   = '/app/data/terminals.json';
const SUBSCRIBERS_FILE = '/app/data/subscribers.json';
const REVENUE_FILE     = '/app/data/revenue-history.json';

function loadJSON(file, fallback = []) {
  try { return JSON.parse(fs.readFileSync(file, 'utf8')); }
  catch { return fallback; }
}
function saveJSON(file, data) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, JSON.stringify(data, null, 2));
}
// ── Revenue history (persistent) ────────────────────────────────────────────
function loadRevenue() {
  if (fs.existsSync(REVENUE_FILE)) {
    try { return JSON.parse(fs.readFileSync(REVENUE_FILE, 'utf8')); } catch(e) {}
  }
  // Seed with zero-scaffold for last 6 months if no file yet
  const months = [];
  const now = new Date();
  for (let i = 5; i >= 0; i--) {
    const d = new Date(now.getFullYear(), now.getMonth() - i, 1);
    months.push({ month: d.toLocaleString('en-US',{month:'short',year:'numeric'}),
      totalRevenue:0, ispShare:0, agentRevenue:0, subscriberCount:0, seeded:true });
  }
  return months;
}
function saveRevenue(history) {
  fs.mkdirSync(path.dirname(REVENUE_FILE), { recursive: true });
  fs.writeFileSync(REVENUE_FILE, JSON.stringify(history, null, 2));
}

// ── Terminals ────────────────────────────────────────────────────────────────
app.get('/api/terminals', (req, res) => {
  res.json(loadJSON(TERMINALS_FILE));
});

app.post('/api/terminals', (req, res) => {
  const { hostname, ip, tier, status } = req.body;
  if (!hostname || !ip) return res.status(400).json({ error: 'hostname and ip are required' });
  const terminals = loadJSON(TERMINALS_FILE);
  const terminal = {
    id: require('crypto').randomUUID(),
    hostname, ip,
    tier: tier || 1,
    status: status || 'provisioning',
    modelVersion: '', lastSeen: new Date().toISOString(),
    osVersion: 'EtherOS 1.0', cpuPercent: 0, ramPercent: 0,
    diskPercent: 0, modelLoaded: '', lastInferenceTime: 0, uptime: '0m',
  };
  terminals.push(terminal);
  saveJSON(TERMINALS_FILE, terminals);
  res.status(201).json(terminal);
});

app.patch('/api/terminals/:id', (req, res) => {
  const terminals = loadJSON(TERMINALS_FILE);
  const idx = terminals.findIndex(t => t.id === req.params.id);
  if (idx === -1) return res.status(404).json({ error: 'Not found' });
  terminals[idx] = { ...terminals[idx], ...req.body, id: terminals[idx].id };
  saveJSON(TERMINALS_FILE, terminals);
  res.json(terminals[idx]);
});

app.delete('/api/terminals/:id', (req, res) => {
  const terminals = loadJSON(TERMINALS_FILE);
  const filtered = terminals.filter(t => t.id !== req.params.id);
  if (filtered.length === terminals.length) return res.status(404).json({ error: 'Not found' });
  saveJSON(TERMINALS_FILE, filtered);
  res.json({ ok: true });
});

// ── Subscribers ──────────────────────────────────────────────────────────────
const PLAN_PRICES = { personal: 14.99, professional: 39.99, charter: 99.99 };

app.get('/api/subscribers', (req, res) => {
  res.json(loadJSON(SUBSCRIBERS_FILE));
});

app.post('/api/subscribers', (req, res) => {
  const { name, email, plan } = req.body;
  if (!name || !email || !plan) return res.status(400).json({ error: 'name, email and plan are required' });
  const subscribers = loadJSON(SUBSCRIBERS_FILE);
  if (subscribers.find(s => s.email === email)) return res.status(409).json({ error: 'Email already exists' });
  const subscriber = {
    id: require('crypto').randomUUID(),
    name, email, plan, status: 'active',
    agentsActive: 0, monthlySpend: PLAN_PRICES[plan] || 0,
    joinedAt: new Date().toISOString(), agents: [],
    billingHistory: [{ date: new Date().toLocaleDateString('en-US',{month:'short',day:'numeric',year:'numeric'}), amount: 0, status: 'trial' }],
  };
  subscribers.push(subscriber);
  saveJSON(SUBSCRIBERS_FILE, subscribers);
  res.status(201).json(subscriber);
});

app.patch('/api/subscribers/:id', (req, res) => {
  const subscribers = loadJSON(SUBSCRIBERS_FILE);
  const idx = subscribers.findIndex(s => s.id === req.params.id);
  if (idx === -1) return res.status(404).json({ error: 'Not found' });
  subscribers[idx] = { ...subscribers[idx], ...req.body, id: subscribers[idx].id };
  saveJSON(SUBSCRIBERS_FILE, subscribers);
  res.json(subscribers[idx]);
});

app.delete('/api/subscribers/:id', (req, res) => {
  const subscribers = loadJSON(SUBSCRIBERS_FILE);
  const filtered = subscribers.filter(s => s.id !== req.params.id);
  if (filtered.length === subscribers.length) return res.status(404).json({ error: 'Not found' });
  saveJSON(SUBSCRIBERS_FILE, filtered);
  res.json({ ok: true });
});

// ── Dashboard KPIs ──────────────────────────────────────────────────────────
app.get('/api/dashboard', (req, res) => {
  const terminals = loadJSON(TERMINALS_FILE);
  const subscribers = loadJSON(SUBSCRIBERS_FILE);
  const online = terminals.filter(t => t.status === 'online').length;
  const offline = terminals.filter(t => t.status === 'offline').length;
  const provisioning = terminals.filter(t => t.status === 'provisioning').length;
  const activeSubs = subscribers.filter(s => s.status === 'active');
  const monthlyRevenue = activeSubs.reduce((sum, s) => sum + (s.monthlySpend || 0), 0);
  const arpu = activeSubs.length > 0 ? Math.round(monthlyRevenue / activeSubs.length) : 0;
  res.json({ totalTerminals: terminals.length, online, offline, provisioning,
    activeSubscribers: activeSubs.length, monthlyRevenue,
    prevMonthlyRevenue: Math.round(monthlyRevenue * 0.95),
    arpu, revenueByMonth: [], activity: [] });
});


// ── Revenue ──────────────────────────────────────────────────────────────────
app.get('/api/revenue', (req, res) => {
  res.json(loadRevenue());
});



// ── Revenue snapshot ─────────────────────────────────────────────────────────
app.post('/api/revenue/snapshot', (req, res) => {
  const subs = loadJSON(SUBSCRIBERS_FILE);
  const active = subs.filter(s => s.status === 'active');
  const totalRevenue = Math.round(active.reduce((s,sub) => s + (sub.monthlySpend||0), 0));
  const agentRevenue = Math.round(active.reduce((s,sub) => s + ((sub.agentsActive||0)*4.99), 0));
  const ispShare     = Math.round(totalRevenue * 0.3);
  const month = new Date().toLocaleString('en-US',{month:'short',year:'numeric',timeZone:'America/Phoenix'});
  const snap = { month, totalRevenue, ispShare, agentRevenue, subscriberCount: active.length };
  const history = loadRevenue();
  const idx = history.findIndex(r => r.month === month);
  if (idx >= 0) history[idx] = snap; else history.push(snap);
  history.sort((a,b) => new Date('1 '+a.month) - new Date('1 '+b.month));
  saveRevenue(history.slice(-24));
  res.json(snap);
});

// ── Terminal self-registration & heartbeat ────────────────────────────────────

setInterval(() => {
  try {
    const terminals = loadJSON(TERMINALS_FILE);
    const now = Date.now();
    let changed = false;
    terminals.forEach(t => {
      if (t.status === 'online' && t.lastSeen) {
        const age = now - new Date(t.lastSeen).getTime();
        if (age > 3 * 60 * 1000) { t.status = 'offline'; changed = true; }
      }
    });
    if (changed) saveJSON(TERMINALS_FILE, terminals);
  } catch {}
}, 60 * 1000);

app.post('/api/terminals/register', (req, res) => {
  const { hostname, ip, osVersion, modelVersion, tier } = req.body;
  if (!hostname || !ip) return res.status(400).json({ error: 'hostname and ip are required' });
  const terminals = loadJSON(TERMINALS_FILE);
  let terminal = terminals.find(t => t.hostname === hostname);
  if (terminal) {
    terminal.ip = ip; terminal.status = 'online';
    terminal.lastSeen = new Date().toISOString();
    terminal.osVersion = osVersion || terminal.osVersion;
    terminal.modelVersion = modelVersion || terminal.modelVersion;
    saveJSON(TERMINALS_FILE, terminals);
    return res.json({ ok: true, terminal, registered: false });
  }
  terminal = {
    id: require('crypto').randomUUID(),
    hostname, ip, tier: tier || 1, status: 'provisioning',
    modelVersion: modelVersion || '', lastSeen: new Date().toISOString(),
    osVersion: osVersion || 'EtherOS 1.0', cpuPercent: 0, ramPercent: 0,
    diskPercent: 0, modelLoaded: '', lastInferenceTime: 0, uptime: '0m',
    registeredAt: new Date().toISOString(),
  };
  terminals.push(terminal);
  saveJSON(TERMINALS_FILE, terminals);
  res.status(201).json({ ok: true, terminal, registered: true });
});

app.post('/api/terminals/:id/heartbeat', (req, res) => {
  const terminals = loadJSON(TERMINALS_FILE);
  const idx = terminals.findIndex(t => t.id === req.params.id);
  if (idx === -1) return res.status(404).json({ error: 'Terminal not found — re-register' });
  const { cpuPercent, ramPercent, diskPercent, modelLoaded, lastInferenceTime, uptime, modelVersion } = req.body;
  terminals[idx] = {
    ...terminals[idx], status: 'online', lastSeen: new Date().toISOString(),
    cpuPercent: cpuPercent ?? terminals[idx].cpuPercent,
    ramPercent: ramPercent ?? terminals[idx].ramPercent,
    diskPercent: diskPercent ?? terminals[idx].diskPercent,
    modelLoaded: modelLoaded ?? terminals[idx].modelLoaded,
    lastInferenceTime: lastInferenceTime ?? terminals[idx].lastInferenceTime,
    uptime: uptime ?? terminals[idx].uptime,
    modelVersion: modelVersion ?? terminals[idx].modelVersion,
  };
  saveJSON(TERMINALS_FILE, terminals);
  res.json({ ok: true, lastSeen: terminals[idx].lastSeen });
});

app.get('/api/terminals/:id', (req, res) => {
  const terminals = loadJSON(TERMINALS_FILE);
  const terminal = terminals.find(t => t.id === req.params.id);
  if (!terminal) return res.status(404).json({ error: 'Not found' });
  res.json(terminal);
});


// ── Terminal self-registration & heartbeat ────────────────────────────────────

setInterval(() => {
  try {
    const terminals = loadJSON(TERMINALS_FILE);
    const now = Date.now();
    let changed = false;
    terminals.forEach(t => {
      if (t.status === 'online' && t.lastSeen) {
        const age = now - new Date(t.lastSeen).getTime();
        if (age > 3 * 60 * 1000) { t.status = 'offline'; changed = true; }
      }
    });
    if (changed) saveJSON(TERMINALS_FILE, terminals);
  } catch {}
}, 60 * 1000);

app.post('/api/terminals/register', (req, res) => {
  const { hostname, ip, osVersion, modelVersion, tier } = req.body;
  if (!hostname || !ip) return res.status(400).json({ error: 'hostname and ip are required' });
  const terminals = loadJSON(TERMINALS_FILE);
  let terminal = terminals.find(t => t.hostname === hostname);
  if (terminal) {
    terminal.ip = ip; terminal.status = 'online';
    terminal.lastSeen = new Date().toISOString();
    terminal.osVersion = osVersion || terminal.osVersion;
    terminal.modelVersion = modelVersion || terminal.modelVersion;
    saveJSON(TERMINALS_FILE, terminals);
    return res.json({ ok: true, terminal, registered: false });
  }
  terminal = {
    id: require('crypto').randomUUID(),
    hostname, ip, tier: tier || 1, status: 'provisioning',
    modelVersion: modelVersion || '', lastSeen: new Date().toISOString(),
    osVersion: osVersion || 'EtherOS 1.0', cpuPercent: 0, ramPercent: 0,
    diskPercent: 0, modelLoaded: '', lastInferenceTime: 0, uptime: '0m',
    registeredAt: new Date().toISOString(),
  };
  terminals.push(terminal);
  saveJSON(TERMINALS_FILE, terminals);
  res.status(201).json({ ok: true, terminal, registered: true });
});

app.post('/api/terminals/:id/heartbeat', (req, res) => {
  const terminals = loadJSON(TERMINALS_FILE);
  const idx = terminals.findIndex(t => t.id === req.params.id);
  if (idx === -1) return res.status(404).json({ error: 'Terminal not found — re-register' });
  const { cpuPercent, ramPercent, diskPercent, modelLoaded, lastInferenceTime, uptime, modelVersion } = req.body;
  terminals[idx] = {
    ...terminals[idx], status: 'online', lastSeen: new Date().toISOString(),
    cpuPercent: cpuPercent ?? terminals[idx].cpuPercent,
    ramPercent: ramPercent ?? terminals[idx].ramPercent,
    diskPercent: diskPercent ?? terminals[idx].diskPercent,
    modelLoaded: modelLoaded ?? terminals[idx].modelLoaded,
    lastInferenceTime: lastInferenceTime ?? terminals[idx].lastInferenceTime,
    uptime: uptime ?? terminals[idx].uptime,
    modelVersion: modelVersion ?? terminals[idx].modelVersion,
  };
  saveJSON(TERMINALS_FILE, terminals);
  res.json({ ok: true, lastSeen: terminals[idx].lastSeen });
});

app.get('/api/terminals/:id', (req, res) => {
  const terminals = loadJSON(TERMINALS_FILE);
  const terminal = terminals.find(t => t.id === req.params.id);
  if (!terminal) return res.status(404).json({ error: 'Not found' });
  res.json(terminal);
});

app.listen(PORT, '0.0.0.0', () => console.log(`ISP Portal backend v1.2.0 (Stripe) running on port ${PORT}`));
