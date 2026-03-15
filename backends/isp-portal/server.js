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

// ── Dashboard KPIs ──────────────────────────────────────────────────────────
app.get('/api/dashboard', (req, res) => {
  res.json({
    totalTerminals: 0,
    online: 0,
    offline: 0,
    provisioning: 0,
    activeSubscribers: 0,
    monthlyRevenue: 0,
    prevMonthlyRevenue: 0,
    arpu: 0,
    revenueByMonth: [],
    activity: [],
  });
});


// ── Revenue ──────────────────────────────────────────────────────────────────
app.get('/api/revenue', (req, res) => {
  // Return empty months scaffold — will populate when subscribers are added
  const months = [];
  const now = new Date();
  for (let i = 5; i >= 0; i--) {
    const d = new Date(now.getFullYear(), now.getMonth() - i, 1);
    months.push({
      month: d.toLocaleString('en-US', { month: 'short', year: 'numeric' }),
      totalRevenue: 0,
      ispShare: 0,
      subscriberCount: 0,
    });
  }
  res.json(months);
});

app.listen(PORT, '0.0.0.0', () => console.log(`ISP Portal backend v1.2.0 (Stripe) running on port ${PORT}`));
