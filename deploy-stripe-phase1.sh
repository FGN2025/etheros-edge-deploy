#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════════
# EtherOS — Deploy Stripe Phase 1 (ISP Portal Billing)
#
# What this does:
#   1. Updates ISP Portal backend server.js with full Stripe billing routes
#   2. Installs stripe npm package in the backend container
#   3. Updates the ISP Portal static frontend (dist)
#   4. Restarts etheros-isp-portal-backend container
#
# Run on VPS:
#   bash <(curl -fsSL https://raw.githubusercontent.com/FGN2025/etheros-edge-deploy/main/deploy-stripe-phase1.sh)
# ═══════════════════════════════════════════════════════════════════════════════
set -euo pipefail

GREEN='\033[0;32m'; CYAN='\033[0;36m'; YELLOW='\033[1;33m'; BOLD='\033[1m'; RED='\033[0;31m'; NC='\033[0m'
EDGE_DIR="/opt/etheros-edge"
GITHUB_RAW="https://raw.githubusercontent.com/FGN2025/etheros-edge-deploy/main"

echo ""
echo -e "${CYAN}${BOLD}━━━ EtherOS — Stripe Phase 1 Deploy ━━━${NC}"
echo ""

# ── Step 1: Update package.json to add stripe ─────────────────────────────────
echo -e "${YELLOW}▸${NC} Updating ISP Portal package.json..."
cat > "$EDGE_DIR/backends/isp-portal/package.json" << 'PKG'
{
  "name": "etheros-isp-portal-backend",
  "version": "1.2.0",
  "type": "commonjs",
  "scripts": { "start": "node server.js" },
  "dependencies": {
    "express": "^4.18.2",
    "cors": "^2.8.5",
    "stripe": "^17.0.0"
  }
}
PKG
echo -e "  ${GREEN}✓${NC} package.json updated"

# ── Step 2: Install stripe in the container ───────────────────────────────────
echo -e "${YELLOW}▸${NC} Installing stripe npm package in container..."
docker exec etheros-isp-portal-backend sh -c "cd /app && npm install stripe --save 2>&1 | tail -3"
echo -e "  ${GREEN}✓${NC} stripe installed"

# ── Step 3: Write full Stripe-enabled server.js ───────────────────────────────
echo -e "${YELLOW}▸${NC} Writing Stripe-enabled server.js..."
cat > "$EDGE_DIR/backends/isp-portal/server.js" << 'JSEOF'
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
const SETTINGS_FILE = '/opt/etheros-edge/data/isp-settings.json';
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
let billingState = {
  customerId: null, subscriptionId: null, planId: null, status: 'none',
  currentPeriodEnd: null, cancelAtPeriodEnd: false, trialEnd: null,
  paymentMethodLast4: null, paymentMethodBrand: null,
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
    stripePriceId: 'price_starter_live', stripePriceIdTest: 'price_starter_test',
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
    stripePriceId: 'price_growth_live', stripePriceIdTest: 'price_growth_test',
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
    stripePriceId: 'price_enterprise_live', stripePriceIdTest: 'price_enterprise_test',
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
      success_url: successUrl || 'https://edge.etheros.ai/isp-portal/#/billing?status=success',
      cancel_url: cancelUrl || 'https://edge.etheros.ai/isp-portal/#/billing?status=canceled',
    };
    if (billingState.customerId) params.customer = billingState.customerId;
    const session = await stripe.checkout.sessions.create(params);
    if (!billingState.customerId && session.customer) {
      billingState.customerId = session.customer;
    }
    res.json({ url: session.url });
  } catch (err) {
    res.status(500).json({ error: String(err) });
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
    const [healthRes, modelsRes] = await Promise.all([
      fetch(`${EDGE_API}/health`, { signal: AbortSignal.timeout(8000) }).catch(() => null),
      fetch(`${EDGE_API}/models`,  { signal: AbortSignal.timeout(8000) }).catch(() => null),
    ]);
    const health = healthRes?.ok ? await healthRes.json().catch(() => null) : null;
    const modelsData = modelsRes?.ok ? await modelsRes.json().catch(() => null) : null;
    const models = (modelsData?.data || []).map(m => m.id || m.name).filter(Boolean);
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
app.listen(PORT, '0.0.0.0', () => console.log(`ISP Portal backend v1.2.0 (Stripe) running on port ${PORT}`));
JSEOF
echo -e "  ${GREEN}✓${NC} server.js written (Stripe-enabled)"

# ── Step 4: Install stripe inside the container ───────────────────────────────
echo -e "${YELLOW}▸${NC} Installing stripe in container..."
docker exec etheros-isp-portal-backend sh -c "cd /app && npm install stripe@^17.0.0 --save --no-audit --no-fund 2>&1 | tail -3" || {
  echo -e "  ${YELLOW}⚠${NC}  Container install failed — will install on host and copy"
  cd "$EDGE_DIR/backends/isp-portal" && npm install stripe@^17.0.0 --save --no-audit --no-fund
}
echo -e "  ${GREEN}✓${NC} stripe npm package installed"

# ── Step 5: Restart backend container ────────────────────────────────────────
echo -e "${YELLOW}▸${NC} Restarting ISP Portal backend..."
docker restart etheros-isp-portal-backend
sleep 3
HEALTH=$(curl -sf http://127.0.0.1:3010/health | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('version','?'))" 2>/dev/null || echo "not ready")
echo -e "  ${GREEN}✓${NC} Backend restarted — version: $HEALTH"

# ── Step 6: Update static frontend ───────────────────────────────────────────
echo -e "${YELLOW}▸${NC} Downloading updated ISP Portal static build..."
curl -fsSL "$GITHUB_RAW/isp-portal-dist.tar.gz" -o /tmp/isp-portal-dist.tar.gz
rm -rf "$EDGE_DIR/static/isp-portal"
mkdir -p "$EDGE_DIR/static/isp-portal"
tar xzf /tmp/isp-portal-dist.tar.gz -C "$EDGE_DIR/static/isp-portal"
echo -e "  ${GREEN}✓${NC} Static files updated ($(ls $EDGE_DIR/static/isp-portal/assets/ | wc -l) assets)"

# ── Step 7: Reload nginx ──────────────────────────────────────────────────────
echo -e "${YELLOW}▸${NC} Reloading nginx..."
docker exec etheros-nginx nginx -t && docker exec etheros-nginx nginx -s reload
echo -e "  ${GREEN}✓${NC} nginx reloaded"

# ── Step 8: Verify ────────────────────────────────────────────────────────────
echo ""
echo -e "${YELLOW}▸${NC} Verifying deployment..."
sleep 2

PORTAL=$(curl -sf -o /dev/null -w "%{http_code}" https://edge.etheros.ai/isp-portal/ || echo "FAIL")
BILLING_API=$(curl -sf -o /dev/null -w "%{http_code}" http://127.0.0.1:3010/api/billing || echo "FAIL")
PLANS_API=$(curl -sf http://127.0.0.1:3010/api/billing/plans | python3 -c "import sys,json; d=json.load(sys.stdin); print(f'{len(d)} plans')" 2>/dev/null || echo "FAIL")

echo -e "  ISP Portal UI:    https://edge.etheros.ai/isp-portal/  → HTTP $PORTAL"
echo -e "  Billing API:      http://127.0.0.1:3010/api/billing    → HTTP $BILLING_API"
echo -e "  Plans API:        http://127.0.0.1:3010/api/billing/plans → $PLANS_API"

echo ""
echo -e "${GREEN}══════════════════════════════════════════════════${NC}"
echo -e "${GREEN}  Stripe Phase 1 deployed!                        ${NC}"
echo -e "${GREEN}══════════════════════════════════════════════════${NC}"
echo ""
echo "  Next steps:"
echo "  1. Go to https://dashboard.stripe.com and create Price IDs for each plan"
echo "  2. Update STRIPE_PLANS in server.js with real Price IDs"
echo "  3. Add your Stripe secret key in ISP Portal → Settings → Billing"
echo "  4. Test with Stripe test mode (sk_test_...)"
echo ""
