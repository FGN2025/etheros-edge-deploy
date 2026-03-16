'use strict';
const express = require('express');
const cors    = require('cors');
const { randomUUID } = require('crypto');

const app = express();

// Raw body for Stripe webhooks (must be before express.json())
app.use('/api/billing/webhook', express.raw({ type: 'application/json' }));
app.use(express.json());
app.use(cors({ origin: '*' }));

const fs   = require('fs');
const path = require('path');

// ── Multi-tenancy: data isolation via TENANT_SLUG env var ─────────────────────
// Each ISP gets its own data directory. On a fresh single-ISP deploy the env
// var is not set and we fall back to /app/data (backward-compatible).
// On a multi-tenant VPS each container is launched with:
//   -e TENANT_SLUG=valley-fiber  → data lives at /app/data/valley-fiber/
const TENANT_SLUG = (process.env.TENANT_SLUG || '').replace(/[^a-z0-9-]/g, '') || null;
const DATA_DIR    = TENANT_SLUG
  ? `/app/data/${TENANT_SLUG}`
  : '/app/data';

// Dynamic domain — read from settings or fall back to TENANT_DOMAIN env var
// so Stripe redirect URLs are always correct for each ISP's domain.
function getPortalDomain() {
  try {
    const s = JSON.parse(fs.readFileSync(SETTINGS_FILE, 'utf8'));
    if (s.domain) return s.domain.replace(/\/$/, '');
  } catch {}
  return (process.env.TENANT_DOMAIN || 'edge.etheros.ai').replace(/\/$/, '');
}
function portalUrl(path = '') {
  return `https://${getPortalDomain()}${path}`;
}

const EDGE_API      = `https://${(process.env.TENANT_DOMAIN || 'edge.etheros.ai').replace(/\/$/, '')}/api`;
const SETTINGS_FILE = `${DATA_DIR}/isp-settings.json`;

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
const BILLING_FILE = `${DATA_DIR}/billing-state.json`;
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
        const base = successUrl || portalUrl('/isp-portal/#/billing?status=success');
        return base + (base.includes('?') ? '&' : '?') + 'session_id={CHECKOUT_SESSION_ID}';
      })(),
      cancel_url: cancelUrl || portalUrl('/isp-portal/#/billing?status=canceled'),
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
      return_url: returnUrl || portalUrl('/isp-portal/#/billing'),
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
      case 'customer.subscription.deleted': {
        const subObj = event.data.object;
        // Sync ISP-level billing state
        if (subObj.id === billingState.subscriptionId || !billingState.subscriptionId) {
          billingState.subscriptionId = subObj.id;
          billingState.customerId = subObj.customer;
          await syncSubscription(stripe, subObj.id);
        }
        // Sync subscriber record by stripeCustomerId
        try {
          const subs = loadJSON(SUBSCRIBERS_FILE);
          const si = subs.findIndex(s => s.stripeCustomerId === subObj.customer);
          if (si >= 0) {
            const status = subObj.status;
            subs[si].billingStatus = status === 'active' ? 'active'
              : status === 'past_due' ? 'past_due'
              : status === 'canceled' ? 'canceled'
              : subs[si].billingStatus || 'invited';
            subs[si].stripeSubscriptionId = subObj.id;
            subs[si].currentPeriodEnd = subObj.current_period_end
              ? new Date(subObj.current_period_end * 1000).toISOString() : null;
            subs[si].cancelAtPeriodEnd = subObj.cancel_at_period_end || false;
            if (event.type === 'customer.subscription.deleted') {
              subs[si].billingStatus = 'canceled';
            }
            saveJSON(SUBSCRIBERS_FILE, subs);
            console.log(`[4G] Subscriber ${subs[si].id} subscription synced: ${status}`);
          }
        } catch (e) { console.error('[4G] Subscriber subscription sync error:', e); }
        break;
      }
      case 'invoice.payment_failed': {
        const inv = event.data.object;
        try {
          const subs = loadJSON(SUBSCRIBERS_FILE);
          const si = subs.findIndex(s => s.stripeCustomerId === inv.customer);
          if (si >= 0) {
            subs[si].billingStatus = 'past_due';
            saveJSON(SUBSCRIBERS_FILE, subs);
            console.log(`[4G] Subscriber ${subs[si].id} marked past_due (payment failed)`);
          }
        } catch (e) { console.error('[4G] invoice.payment_failed sync error:', e); }
        break;
      }
      case 'checkout.session.completed': {
        const sess = event.data.object;
        if (sess.subscription) {
          billingState.customerId = sess.customer;
          billingState.subscriptionId = sess.subscription;
          saveBillingState(billingState);
          await syncSubscription(stripe, sess.subscription);
        }
        // Sync subscriber record if this was a subscriber billing checkout
        if (sess.metadata && sess.metadata.subscriberId) {
          try {
            const subs = loadJSON(SUBSCRIBERS_FILE);
            const si = subs.findIndex(s => s.id === sess.metadata.subscriberId);
            if (si >= 0) {
              subs[si].stripeCustomerId = sess.customer || subs[si].stripeCustomerId;
              if (sess.subscription) subs[si].stripeSubscriptionId = sess.subscription;
              subs[si].billingStatus = 'active';
              if (sess.metadata.plan) subs[si].plan = sess.metadata.plan;
              saveJSON(SUBSCRIBERS_FILE, subs);
              console.log(`[4G] Subscriber ${sess.metadata.subscriberId} billing activated`);
            }
          } catch (e) { console.error('[4G] Subscriber sync error:', e); }
        }
        // Auto-provision new ISP tenant if this is a sign-up checkout
        if (sess.metadata && sess.metadata.provision_type === 'new_isp' && sess.metadata.isp_slug) {
          const m = sess.metadata;
          const slug = m.isp_slug.replace(/[^a-z0-9-]/g, '-');
          const tenantDir = `/app/data/${slug}`;
          const settingsFile = `${tenantDir}/isp-settings.json`;
          const configFile = `/app/isp-config/${slug}.json`;
          try {
            fs.mkdirSync(tenantDir, { recursive: true });
            fs.mkdirSync('/app/isp-config', { recursive: true });
            if (!fs.existsSync(settingsFile)) {
              fs.writeFileSync(settingsFile, JSON.stringify({
                ispName: m.isp_name || slug,
                domain: m.isp_domain || '',
                accentColor: '#00C2CB',
                logoUrl: '',
                supportEmail: m.isp_email || `support@${m.isp_domain || slug + '.com'}`,
                stripeKey: '', stripeWebhookSecret: '',
              }, null, 2));
            }
            if (!fs.existsSync(configFile)) {
              fs.writeFileSync(configFile, JSON.stringify({
                slug, name: m.isp_name || slug,
                domain: m.isp_domain || '',
                logo_url: '', accent_color: '#00C2CB',
                support_email: m.isp_email || '',
                stripe_customer_id: sess.customer,
                stripe_subscription_id: sess.subscription,
                provisioned_at: new Date().toISOString(),
              }, null, 2));
            }
            // Append to provisioning log
            const logPath = '/app/data/provisioning-log.json';
            let log = [];
            try { log = JSON.parse(fs.readFileSync(logPath, 'utf8')); } catch {}
            log.push({ slug, ispName: m.isp_name, domain: m.isp_domain, email: m.isp_email,
              stripeCustomerId: sess.customer, provisionedAt: new Date().toISOString() });
            fs.writeFileSync(logPath, JSON.stringify(log, null, 2));
            console.log(`[4B] Provisioned new ISP tenant: ${slug}`);
          } catch (provErr) {
            console.error('[4B] Auto-provision failed:', provErr);
          }
        }
        break;
      }
    }
    res.json({ received: true });
  } catch (err) {
    console.error('Webhook handler error:', err);
    res.status(500).json({ error: String(err) });
  }
});

// ── POST /api/billing/isp-signup ────────────────────────────────────────────
// Creates a Stripe checkout session for a NEW ISP signing up.
// Stores ISP metadata in Stripe session metadata so the webhook can provision.
app.post('/api/billing/isp-signup', async (req, res) => {
  const stripe = getStripe();
  if (!stripe) return res.status(400).json({ error: 'Stripe not configured on this node.' });

  const { planId, ispName, contactEmail, slug, domain, city, state, successUrl, cancelUrl, accentColor } = req.body;
  if (!planId || !ispName || !contactEmail || !slug) {
    return res.status(400).json({ error: 'planId, ispName, contactEmail, and slug are required.' });
  }

  const plan = STRIPE_PLANS.find(p => p.id === planId);
  if (!plan) return res.status(400).json({ error: 'Unknown plan' });

  const settings = loadSettings();
  const isTest   = settings.stripeKey?.startsWith('sk_test_');
  const priceId  = isTest ? plan.stripePriceIdTest : plan.stripePriceId;

  try {
    // Create (or retrieve) a Stripe customer for this ISP
    const customer = await stripe.customers.create({
      email: contactEmail,
      name: ispName,
      metadata: { isp_slug: slug, isp_domain: domain || '', isp_city: city || '', isp_state: state || '' },
    });

    const base = successUrl || portalUrl('/isp-portal/#/signup/success');
    const session = await stripe.checkout.sessions.create({
      mode: 'subscription',
      customer: customer.id,
      line_items: [{ price: priceId, quantity: 1 }],
      subscription_data: {
        trial_period_days: 14,
        metadata: { isp_slug: slug, isp_name: ispName, isp_domain: domain || '' },
      },
      success_url: base + (base.includes('?') ? '&' : '?') + 'session_id={CHECKOUT_SESSION_ID}',
      cancel_url: cancelUrl || portalUrl('/isp-portal/#/signup'),
      metadata: {
        isp_slug: slug, isp_name: ispName, isp_domain: domain || '',
        isp_email: contactEmail, isp_city: city || '', isp_state: state || '',
        isp_accent: accentColor || '#00C2CB',
        provision_type: 'new_isp',
      },
    });
    res.json({ url: session.url });
  } catch (err) {
    res.status(500).json({ error: String(err) });
  }
});

// ── POST /api/billing/provision-tenant ───────────────────────────────────────
// Called by the success page after checkout to ensure tenant data exists.
// Also called automatically by the Stripe webhook on checkout.session.completed.
// Sprint 4C: also spins up isolated Docker container + nginx vhost.
app.post('/api/billing/provision-tenant', async (req, res) => {
  const { sessionId, slug: directSlug, ispName: directName, domain: directDomain, email: directEmail, accentColor: directAccent } = req.body || {};

  let slug = directSlug, ispName = directName, domain = directDomain, email = directEmail, accentColor = directAccent || '#00C2CB';

  // If sessionId provided, pull metadata from Stripe
  if (sessionId) {
    const stripe = getStripe();
    if (stripe) {
      try {
        const session = await stripe.checkout.sessions.retrieve(sessionId);
        const m = session.metadata || {};
        slug        = slug        || m.isp_slug;
        ispName     = ispName     || m.isp_name;
        domain      = domain      || m.isp_domain;
        email       = email       || m.isp_email;
        accentColor = accentColor || m.isp_accent || '#00C2CB';
      } catch {}
    }
  }

  if (!slug) return res.status(400).json({ error: 'slug is required' });

  slug = slug.replace(/[^a-z0-9-]/g, '-').replace(/(^-|-$)/g, '');
  const tenantDataDir = `/app/data/${slug}`;
  const settingsPath  = `${tenantDataDir}/isp-settings.json`;
  const configPath    = `/app/isp-config/${slug}.json`;
  const containerName = `etheros-isp-${slug}`;
  const steps = [];

  try {
    const fsMod = require('fs');
    const { execSync } = require('child_process');

    // 1. Create data directory
    fsMod.mkdirSync(tenantDataDir, { recursive: true });
    fsMod.mkdirSync('/app/isp-config', { recursive: true });
    steps.push('data_dir');

    // 2. Seed isp-settings.json if not present
    if (!fsMod.existsSync(settingsPath)) {
      fsMod.writeFileSync(settingsPath, JSON.stringify({
        ispName: ispName || slug,
        domain: domain || '',
        accentColor,
        logoUrl: '',
        supportEmail: email || `support@${domain || slug + '.com'}`,
        stripeKey: '',
        stripeWebhookSecret: '',
      }, null, 2));
    }
    steps.push('settings');

    // 3. Write tenant config JSON
    if (!fsMod.existsSync(configPath)) {
      fsMod.writeFileSync(configPath, JSON.stringify({
        slug,
        name: ispName || slug,
        domain: domain || '',
        logo_url: '',
        accent_color: accentColor,
        support_email: email || `support@${domain || slug + '.com'}`,
        provisioned_at: new Date().toISOString(),
      }, null, 2));
    }
    steps.push('config');

    // 4. Log provision event
    const logPath = '/app/data/provisioning-log.json';
    let log = [];
    try { log = JSON.parse(fsMod.readFileSync(logPath, 'utf8')); } catch {}
    const alreadyLogged = log.some(e => e.slug === slug);
    if (!alreadyLogged) {
      log.push({ slug, ispName, domain, email, accentColor, provisionedAt: new Date().toISOString() });
      fsMod.writeFileSync(logPath, JSON.stringify(log, null, 2));
    }
    steps.push('log');

    // 5. Spin up isolated Docker container (idempotent — skip if already running)
    let containerStatus = 'skipped';
    try {
      const running = execSync(
        `docker ps --filter name=^${containerName}$ --format '{{.Status}}'`,
        { encoding: 'utf8' }
      ).trim();

      if (!running) {
        // Auto-assign next free port in 3020-3099
        let port = 3020;
        const usedPorts = execSync(
          `docker ps --format '{{.Ports}}' 2>/dev/null || true`,
          { encoding: 'utf8' }
        );
        while (usedPorts.includes(`127.0.0.1:${port}->`) && port < 3100) port++;

        execSync([
          'docker run -d',
          `--name ${containerName}`,
          '--network etheros-edge_edge-internal',
          '--restart unless-stopped',
          `-p 127.0.0.1:${port}:3010`,
          '-v /opt/etheros-edge/backends/isp-portal:/app:rw',
          `-e TENANT_SLUG=${slug}`,
          `-e TENANT_DOMAIN=${domain || 'edge.etheros.ai'}`,
          '-e NODE_ENV=production',
          `--label etheros.tenant=${slug}`,
          `--label etheros.domain=${domain || ''}`,
          'etheros-edge_etheros-isp-portal-backend',
        ].join(' '), { encoding: 'utf8' });

        // Update config with assigned port
        try {
          const cfg = JSON.parse(fsMod.readFileSync(configPath, 'utf8'));
          cfg.backend_port = port;
          fsMod.writeFileSync(configPath, JSON.stringify(cfg, null, 2));
        } catch {}

        containerStatus = `started:${port}`;
        steps.push(`container:${port}`);
      } else {
        containerStatus = `already_running`;
        steps.push('container:already_running');
      }
    } catch (dockerErr) {
      console.error('[4C] Docker container spawn failed:', dockerErr.message);
      containerStatus = `error:${dockerErr.message}`;
      steps.push('container:error');
    }

    // 6. Generate nginx vhost and reload (only if domain is set)
    let nginxStatus = 'skipped';
    if (domain) {
      try {
        const nginxConfDir  = '/opt/etheros-edge/nginx/conf.d';
        const templatePath  = '/opt/etheros-edge/nginx/tenant-vhost.conf.template';
        const vhostPath     = `${nginxConfDir}/${slug}.conf`;

        if (!fsMod.existsSync(vhostPath) && fsMod.existsSync(templatePath)) {
          const cfg      = JSON.parse(fsMod.readFileSync(configPath, 'utf8'));
          const port     = cfg.backend_port || 3020;
          const template = fsMod.readFileSync(templatePath, 'utf8');
          const vhost    = template
            .replace(/__DOMAIN__/g, domain)
            .replace(/__SLUG__/g, slug)
            .replace(/__ISP_NAME__/g, ispName || slug)
            .replace(/__ACCENT_COLOR__/g, accentColor)
            .replace(/__PORT__/g, String(port));
          fsMod.mkdirSync(nginxConfDir, { recursive: true });
          fsMod.writeFileSync(vhostPath, vhost);

          // Reload nginx
          execSync('docker exec etheros-nginx nginx -s reload', { encoding: 'utf8' });
          nginxStatus = 'reloaded';
          steps.push('nginx:reloaded');
        } else if (fsMod.existsSync(vhostPath)) {
          nginxStatus = 'already_exists';
          steps.push('nginx:already_exists');
        } else {
          nginxStatus = 'template_not_found';
          steps.push('nginx:template_not_found');
        }
      } catch (nginxErr) {
        console.error('[4C] Nginx vhost generation failed:', nginxErr.message);
        nginxStatus = `error:${nginxErr.message}`;
        steps.push('nginx:error');
      }
    }

    res.json({
      ok: true,
      slug,
      ispName: ispName || slug,
      domain: domain || '',
      portalUrl: domain ? `https://${domain}/isp-portal/` : `https://edge.etheros.ai/isp-portal/`,
      dataDir: tenantDataDir,
      containerStatus,
      nginxStatus,
      steps,
    });
  } catch (err) {
    console.error('Provision tenant error:', err);
    res.status(500).json({ error: String(err), steps });
  }
});

// ── GET /api/billing/tenants ──────────────────────────────────────────────────
// List all provisioned ISP tenants with live Docker container status.
app.get('/api/billing/tenants', (req, res) => {
  try {
    const fsMod = require('fs');
    const { execSync } = require('child_process');

    // Read provisioning log
    const logPath = '/app/data/provisioning-log.json';
    let log = [];
    try { log = JSON.parse(fsMod.readFileSync(logPath, 'utf8')); } catch {}

    // Scan isp-config dir for canonical tenant list
    const configDir = '/app/isp-config';
    let configs = [];
    if (fsMod.existsSync(configDir)) {
      configs = fsMod.readdirSync(configDir)
        .filter(f => f.endsWith('.json'))
        .map(f => {
          try { return JSON.parse(fsMod.readFileSync(`${configDir}/${f}`, 'utf8')); }
          catch { return null; }
        })
        .filter(Boolean);
    }

    // Get live Docker status for each tenant container
    let dockerStatus = {};
    try {
      const lines = execSync(
        `docker ps -a --filter label=etheros.tenant --format '{{.Names}}\t{{.Status}}'`,
        { encoding: 'utf8' }
      ).trim().split('\n').filter(Boolean);
      for (const line of lines) {
        const [name, ...rest] = line.split('\t');
        const slug = name.replace('etheros-isp-', '');
        dockerStatus[slug] = rest.join('\t');
      }
    } catch {}

    // Merge container status into configs
    const enriched = configs.map(c => ({
      ...c,
      container: {
        name: `etheros-isp-${c.slug}`,
        status: dockerStatus[c.slug] || 'not_started',
        healthy: (dockerStatus[c.slug] || '').toLowerCase().startsWith('up'),
      },
      portalUrl: c.domain
        ? `https://${c.domain}/isp-portal/`
        : `https://edge.etheros.ai/isp-portal/`,
    }));

    res.json({ tenants: enriched, provisioningLog: log });
  } catch (err) {
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
      edgeUrl: portalUrl(''),
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
    const _s = loadSettings();
    res.json([{ slug: TENANT_SLUG || 'etheros-default', name: _s.ispName || 'EtherOS AI', domain: _s.domain || getPortalDomain(), accent_color: _s.accentColor || '#00C2CB' }]);
  }
});

// ── POST /api/chat/stream ────────────────────────────────────────────────────
// Subscriber terminal inline chat — streams Ollama responses as SSE.
// Validates the subscriber token, then proxies to Ollama /api/chat.
app.post('/api/chat/stream', async (req, res) => {
  const auth = req.headers.authorization || '';
  const token = auth.startsWith('Bearer ') ? auth.slice(7) : '';
  const subscriberId = parseToken(token);
  if (!subscriberId) return res.status(401).json({ error: 'Invalid or expired session' });

  const { model, systemPrompt, messages } = req.body || {};
  if (!messages || !Array.isArray(messages)) {
    return res.status(400).json({ error: 'messages array required' });
  }

  const ollamaMessages = [
    ...(systemPrompt ? [{ role: 'system', content: systemPrompt }] : []),
    ...messages,
  ];

  const ollamaUrl = 'http://etheros-ollama:11434/api/chat';
  const ollamaModel = model || 'llama3.1:8b';

  try {
    const upstream = await fetch(ollamaUrl, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ model: ollamaModel, messages: ollamaMessages, stream: true }),
    });

    if (!upstream.ok) {
      return res.status(502).json({ error: 'Ollama unavailable', status: upstream.status });
    }

    res.setHeader('Content-Type', 'text/event-stream');
    res.setHeader('Cache-Control', 'no-cache');
    res.setHeader('Connection', 'keep-alive');
    res.setHeader('X-Accel-Buffering', 'no');
    res.flushHeaders();

    const reader = upstream.body.getReader();
    const decoder = new TextDecoder();

    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      const chunk = decoder.decode(value, { stream: true });
      const lines = chunk.split('\n').filter(Boolean);
      for (const line of lines) {
        try {
          const parsed = JSON.parse(line);
          const delta = parsed.message?.content || '';
          if (delta) {
            res.write(`data: ${JSON.stringify({ choices: [{ delta: { content: delta } }] })}\n\n`);
          }
          if (parsed.done) {
            res.write('data: [DONE]\n\n');
            res.end();
            return;
          }
        } catch {}
      }
    }
    res.write('data: [DONE]\n\n');
    res.end();
  } catch (err) {
    console.error('[chat/stream] error:', err.message);
    if (!res.headersSent) res.status(502).json({ error: 'Upstream error' });
    else res.end();
  }
});

// ── Health ────────────────────────────────────────────────────────────────────
// GET /api/tenant — lightweight branding info for the frontend shell
app.get('/api/tenant', (req, res) => {
  const s = loadSettings();
  const name = s.ispName || 'EtherOS';
  const initials = name.split(' ').map(w => w[0]).join('').slice(0, 2).toUpperCase();
  res.json({
    slug:        TENANT_SLUG || 'default',
    name,
    initials,
    domain:      s.domain      || getPortalDomain(),
    accentColor: s.accentColor || '#00C2CB',
    logoUrl:     s.logoUrl     || null,
  });
});

app.get('/health', (req, res) => {
  const s = loadSettings();
  res.json({
    status: 'ok',
    service: 'isp-portal-backend',
    version: '2.0.0-multitenant',
    tenant: TENANT_SLUG || 'default',
    ispName: s.ispName || null,
    domain: s.domain || getPortalDomain(),
    ts: new Date().toISOString(),
  });
});

const PORT = process.env.PORT || 3010;


// ── JSON file storage helpers ─────────────────────────────────────────────────
const TERMINALS_FILE   = `${DATA_DIR}/terminals.json`;
const SUBSCRIBERS_FILE = `${DATA_DIR}/subscribers.json`;
const REVENUE_FILE     = `${DATA_DIR}/revenue-history.json`;

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

// ── Phase 2: Subscriber Stripe Billing ───────────────────────────────────────

const SUBSCRIBER_PLANS = {
  personal:     { name: 'Personal',     priceMonthly: 1499, priceId: 'price_1TBPB5ERnCKuXiJaJSsWJBTw' },
  professional: { name: 'Professional', priceMonthly: 3999, priceId: 'price_1TBPCzERnCKuXiJagZEPZAVk' },
  charter:      { name: 'Charter',      priceMonthly: 9999, priceId: 'price_1TBPCzERnCKuXiJaB8DWJ84N' },
};

// POST /api/subscribers/billing/batch-invite — MUST be before /:id routes to avoid routing conflict
app.post('/api/subscribers/billing/batch-invite', async (req, res) => {
  const stripe = getStripe();
  if (!stripe) return res.status(400).json({ error: 'Stripe not configured. Add your Stripe secret key in Settings.' });

  const subscribers = loadJSON(SUBSCRIBERS_FILE);
  const { successUrl, cancelUrl } = req.body;

  const unbilled = subscribers.filter(s => !s.billingStatus || s.billingStatus === 'none');
  let invited = 0;
  let skipped = 0;
  let errors = 0;

  for (const sub of unbilled) {
    const plan = SUBSCRIBER_PLANS[sub.plan];
    if (!plan) { skipped++; continue; }
    try {
      const params = {
        mode: 'subscription',
        line_items: [{ price: plan.priceId, quantity: 1 }],
        customer_email: sub.email,
        success_url: successUrl || portalUrl('/isp-portal/#/subscribers?billing=success'),
        cancel_url: cancelUrl || portalUrl('/isp-portal/#/subscribers?billing=canceled'),
        metadata: { subscriberId: sub.id, plan: sub.plan },
      };
      const session = await stripe.checkout.sessions.create(params);
      const idx = subscribers.findIndex(s => s.id === sub.id);
      subscribers[idx].billingStatus = 'invited';
      subscribers[idx].billingInvitedAt = new Date().toISOString();
      subscribers[idx].stripeCheckoutSessionId = session.id;
      invited++;
    } catch (err) {
      console.error('batch-invite error for', sub.email, err.message);
      errors++;
    }
  }

  saveJSON(SUBSCRIBERS_FILE, subscribers);
  const alreadyBilled = subscribers.length - unbilled.length;
  res.json({ invited, skipped: alreadyBilled + skipped, errors, total: subscribers.length });
});

// POST /api/subscribers/:id/billing/checkout — create Stripe checkout for a subscriber
app.post('/api/subscribers/:id/billing/checkout', async (req, res) => {
  const stripe = getStripe();
  if (!stripe) return res.status(400).json({ error: 'Stripe not configured. Add your Stripe secret key in Settings.' });

  const subscribers = loadJSON(SUBSCRIBERS_FILE);
  const idx = subscribers.findIndex(s => s.id === req.params.id);
  if (idx < 0) return res.status(404).json({ error: 'Subscriber not found' });

  const subscriber = subscribers[idx];
  const plan = SUBSCRIBER_PLANS[subscriber.plan];
  if (!plan) return res.status(400).json({ error: 'Unknown plan: ' + subscriber.plan });

  const { successUrl, cancelUrl } = req.body;

  try {
    const params = {
      mode: 'subscription',
      line_items: [{ price: plan.priceId, quantity: 1 }],
      customer_email: subscriber.stripeCustomerId ? undefined : subscriber.email,
      success_url: successUrl || portalUrl('/isp-portal/#/subscribers?billing=success'),
      cancel_url: cancelUrl || portalUrl('/isp-portal/#/subscribers?billing=canceled'),
      metadata: {
        subscriberId: subscriber.id,
        plan: subscriber.plan,
        ispName: loadSettings().ispName || 'EtherOS',
      },
    };
    if (subscriber.stripeCustomerId) params.customer = subscriber.stripeCustomerId;

    const session = await stripe.checkout.sessions.create(params);

    // Save customerId + mark as invited
    subscriber.stripeCustomerId = subscriber.stripeCustomerId || (session.customer || null);
    subscriber.billingStatus = 'invited';
    subscriber.billingInvitedAt = new Date().toISOString();
    subscribers[idx] = subscriber;
    saveJSON(SUBSCRIBERS_FILE, subscribers);

    res.json({ checkoutUrl: session.url, sessionId: session.id, subscriber });
  } catch (err) {
    console.error('Subscriber checkout error:', err.message);
    res.status(500).json({ error: err.message });
  }
});

// POST /api/subscribers/:id/billing/portal — Stripe customer portal for a subscriber
app.post('/api/subscribers/:id/billing/portal', async (req, res) => {
  const stripe = getStripe();
  if (!stripe) return res.status(400).json({ error: 'Stripe not configured' });

  const subscribers = loadJSON(SUBSCRIBERS_FILE);
  const sub = subscribers.find(s => s.id === req.params.id);
  if (!sub) return res.status(404).json({ error: 'Subscriber not found' });
  if (!sub.stripeCustomerId) return res.status(400).json({ error: 'No Stripe customer for this subscriber' });

  const { returnUrl } = req.body;
  try {
    const session = await stripe.billingPortal.sessions.create({
      customer: sub.stripeCustomerId,
      return_url: returnUrl || portalUrl('/isp-portal/#/subscribers'),
    });
    res.json({ portalUrl: session.url });
  } catch (err) {
    console.error('Subscriber portal error:', err.message);
    res.status(500).json({ error: err.message });
  }
});

// GET /api/subscribers/:id/billing — billing status for a specific subscriber
app.get('/api/subscribers/:id/billing', async (req, res) => {
  const subscribers = loadJSON(SUBSCRIBERS_FILE);
  const sub = subscribers.find(s => s.id === req.params.id);
  if (!sub) return res.status(404).json({ error: 'Subscriber not found' });

  const stripe = getStripe();
  if (stripe && sub.stripeSubscriptionId) {
    try {
      const stripeSub = await stripe.subscriptions.retrieve(sub.stripeSubscriptionId);
      // Sync status back
      const subIdx = subscribers.findIndex(s => s.id === req.params.id);
      subscribers[subIdx].billingStatus = stripeSub.status === 'active' ? 'active'
        : stripeSub.status === 'past_due' ? 'past_due'
        : stripeSub.status === 'canceled' ? 'canceled'
        : sub.billingStatus || 'invited';
      saveJSON(SUBSCRIBERS_FILE, subscribers);
      return res.json(subscribers[subIdx]);
    } catch {}
  }
  res.json(sub);
});

// POST /api/subscribers/:id/billing/upgrade — change plan via Stripe Checkout
// Used by subscriber terminal (Option A: token from session)
app.post('/api/subscribers/:id/billing/upgrade', async (req, res) => {
  const stripe = getStripe();
  if (!stripe) return res.status(400).json({ error: 'Stripe not configured' });

  // Auth: subscriber token OR admin token
  const auth = req.headers.authorization || '';
  const token = auth.startsWith('Bearer ') ? auth.slice(7) : null;
  const subscribers = loadJSON(SUBSCRIBERS_FILE);
  const sub = subscribers.find(s => s.id === req.params.id);
  if (!sub) return res.status(404).json({ error: 'Subscriber not found' });
  const settings = loadSettings();
  const isAdmin = req.headers['x-admin-token'] === settings.adminToken;
  const isSubscriber = token && sub.token === token;
  if (!isAdmin && !isSubscriber) return res.status(403).json({ error: 'Forbidden' });

  const { newPlan, successUrl, cancelUrl } = req.body;
  const plan = SUBSCRIBER_PLANS[newPlan];
  if (!plan) return res.status(400).json({ error: 'Invalid plan: ' + newPlan });

  try {
    // If subscriber already has an active subscription, update it immediately via Stripe API
    if (sub.stripeSubscriptionId) {
      const stripeSub = await stripe.subscriptions.retrieve(sub.stripeSubscriptionId);
      const itemId = stripeSub.items.data[0]?.id;
      if (itemId) {
        await stripe.subscriptions.update(sub.stripeSubscriptionId, {
          items: [{ id: itemId, price: plan.priceId }],
          proration_behavior: 'create_prorations',
          metadata: { subscriberId: sub.id, plan: newPlan },
        });
        const idx = subscribers.findIndex(s => s.id === sub.id);
        subscribers[idx].plan = newPlan;
        subscribers[idx].billingStatus = 'active';
        saveJSON(SUBSCRIBERS_FILE, subscribers);
        return res.json({ ok: true, upgraded: true, plan: newPlan });
      }
    }
    // No active subscription — create Checkout session
    const params = {
      mode: 'subscription',
      line_items: [{ price: plan.priceId, quantity: 1 }],
      customer_email: sub.stripeCustomerId ? undefined : sub.email,
      success_url: successUrl || portalUrl(`/#/terminal?billing=success`),
      cancel_url: cancelUrl || portalUrl(`/#/terminal?billing=canceled`),
      metadata: { subscriberId: sub.id, plan: newPlan },
    };
    if (sub.stripeCustomerId) params.customer = sub.stripeCustomerId;
    const session = await stripe.checkout.sessions.create(params);
    res.json({ checkoutUrl: session.url, sessionId: session.id });
  } catch (err) {
    console.error('[4G] Upgrade error:', err.message);
    res.status(500).json({ error: err.message });
  }
});

// POST /api/subscribers/:id/billing/cancel — cancel at period end
app.post('/api/subscribers/:id/billing/cancel', async (req, res) => {
  const stripe = getStripe();
  if (!stripe) return res.status(400).json({ error: 'Stripe not configured' });

  const auth = req.headers.authorization || '';
  const token = auth.startsWith('Bearer ') ? auth.slice(7) : null;
  const subscribers = loadJSON(SUBSCRIBERS_FILE);
  const idx = subscribers.findIndex(s => s.id === req.params.id);
  if (idx < 0) return res.status(404).json({ error: 'Subscriber not found' });
  const sub = subscribers[idx];
  const settings = loadSettings();
  const isAdmin = req.headers['x-admin-token'] === settings.adminToken;
  const isSubscriber = token && sub.token === token;
  if (!isAdmin && !isSubscriber) return res.status(403).json({ error: 'Forbidden' });
  if (!sub.stripeSubscriptionId) return res.status(400).json({ error: 'No active subscription' });

  try {
    await stripe.subscriptions.update(sub.stripeSubscriptionId, { cancel_at_period_end: true });
    subscribers[idx].cancelAtPeriodEnd = true;
    saveJSON(SUBSCRIBERS_FILE, subscribers);
    res.json({ ok: true, cancelAtPeriodEnd: true });
  } catch (err) {
    console.error('[4G] Cancel error:', err.message);
    res.status(500).json({ error: err.message });
  }
});

// POST /api/subscribers/:id/billing/reactivate — undo cancel_at_period_end
app.post('/api/subscribers/:id/billing/reactivate', async (req, res) => {
  const stripe = getStripe();
  if (!stripe) return res.status(400).json({ error: 'Stripe not configured' });

  const auth = req.headers.authorization || '';
  const token = auth.startsWith('Bearer ') ? auth.slice(7) : null;
  const subscribers = loadJSON(SUBSCRIBERS_FILE);
  const idx = subscribers.findIndex(s => s.id === req.params.id);
  if (idx < 0) return res.status(404).json({ error: 'Subscriber not found' });
  const sub = subscribers[idx];
  const settings = loadSettings();
  const isAdmin = req.headers['x-admin-token'] === settings.adminToken;
  const isSubscriber = token && sub.token === token;
  if (!isAdmin && !isSubscriber) return res.status(403).json({ error: 'Forbidden' });
  if (!sub.stripeSubscriptionId) return res.status(400).json({ error: 'No active subscription' });

  try {
    await stripe.subscriptions.update(sub.stripeSubscriptionId, { cancel_at_period_end: false });
    subscribers[idx].cancelAtPeriodEnd = false;
    saveJSON(SUBSCRIBERS_FILE, subscribers);
    res.json({ ok: true, cancelAtPeriodEnd: false });
  } catch (err) {
    console.error('[4G] Reactivate error:', err.message);
    res.status(500).json({ error: err.message });
  }
});

// ── Agents ────────────────────────────────────────────────────────────────────

const AGENTS_FILE = `${DATA_DIR}/agents.json`;

const PLAN_AGENT_LIMITS = { personal: 3, professional: 10, charter: 999 };

const DEFAULT_AGENTS = [
  { id: 'agent-001', name: 'Rural Support Assistant', slug: 'rural-support', description: 'Answers common rural broadband questions, outage updates, and billing FAQs for end users.', category: 'Support', creatorRole: 'etheros', status: 'live', pricingType: 'free', priceMonthly: 0, activationCount: 0, isEnabled: true, modelId: 'llama3.1:8b', systemPrompt: 'You are a helpful rural ISP support assistant. Answer questions about internet service, outages, billing, and equipment in a friendly and simple way.' },
  { id: 'agent-002', name: 'Community Bulletin', slug: 'community-bulletin', description: 'Shares local news, events, and community announcements tailored to the subscriber\'s area.', category: 'Community', creatorRole: 'etheros', status: 'live', pricingType: 'free', priceMonthly: 0, activationCount: 0, isEnabled: true, modelId: 'llama3.1:8b', systemPrompt: 'You are a friendly community assistant for a rural area. Share local news, events, weather, and community information.' },
  { id: 'agent-003', name: 'HomeSchool Tutor', slug: 'homeschool-tutor', description: 'Patient K-12 tutoring assistant for homeschool families covering math, science, reading, and history.', category: 'Learning', creatorRole: 'etheros', status: 'live', pricingType: 'free', priceMonthly: 0, activationCount: 0, isEnabled: true, modelId: 'llama3.1:8b', systemPrompt: 'You are a patient, encouraging K-12 tutor. Help students with math, science, reading, writing, and history. Explain concepts simply and check for understanding.' },
  { id: 'agent-004', name: 'Farm & Ranch Advisor', slug: 'farm-ranch-advisor', description: 'Agronomic and livestock guidance for small farms — planting schedules, soil health, pest management.', category: 'Agriculture', creatorRole: 'etheros', status: 'live', pricingType: 'free', priceMonthly: 0, activationCount: 0, isEnabled: true, modelId: 'llama3.1:8b', systemPrompt: 'You are an agricultural advisor for small farms and ranches. Provide practical guidance on crops, livestock, soil health, irrigation, and pest management.' },
  { id: 'agent-005', name: 'Health Navigator', slug: 'health-navigator', description: 'General health information, symptom guidance, and telehealth navigation for rural households.', category: 'Health', creatorRole: 'etheros', status: 'live', pricingType: 'free', priceMonthly: 0, activationCount: 0, isEnabled: true, modelId: 'llama3.1:8b', systemPrompt: 'You are a general health information assistant. Provide helpful health information, help users understand symptoms, and guide them to appropriate care. Always recommend consulting a doctor for medical decisions.' },
  { id: 'agent-006', name: 'Small Biz Coach', slug: 'small-biz-coach', description: 'Business planning, marketing, and operations advice for rural small business owners.', category: 'Business', creatorRole: 'etheros', status: 'live', pricingType: 'addon', priceMonthly: 4.99, activationCount: 0, isEnabled: true, modelId: 'llama3.1:8b', systemPrompt: 'You are a small business coach for rural entrepreneurs. Help with business planning, marketing strategies, financial basics, and operational challenges.' },
  { id: 'agent-007', name: 'Legal Q&A', slug: 'legal-qa', description: 'Plain-language explanations of common legal questions — leases, contracts, employment, and property.', category: 'Business', creatorRole: 'etheros', status: 'live', pricingType: 'addon', priceMonthly: 4.99, activationCount: 0, isEnabled: true, modelId: 'llama3.1:8b', systemPrompt: 'You provide plain-language explanations of common legal concepts. Always clarify you are not a lawyer and recommend consulting one for specific legal advice.' },
  { id: 'agent-008', name: 'Dev Sandbox', slug: 'dev-sandbox', description: 'Code assistant for developers — debugging, snippets, and architecture guidance across popular languages.', category: 'Development', creatorRole: 'etheros', status: 'live', pricingType: 'addon', priceMonthly: 4.99, activationCount: 0, isEnabled: false, modelId: 'llama3.1:8b', systemPrompt: 'You are an expert software developer assistant. Help with code debugging, writing code snippets, explaining concepts, and software architecture across all major languages.' },
  { id: 'agent-009', name: 'Data Analyst', slug: 'data-analyst', description: 'Helps interpret spreadsheets, charts, and business data — ideal for small business analytics.', category: 'Analytics', creatorRole: 'etheros', status: 'live', pricingType: 'addon', priceMonthly: 9.99, activationCount: 0, isEnabled: false, modelId: 'llama3.1:8b', systemPrompt: 'You are a data analysis assistant. Help users understand their data, create summaries, identify trends, and make data-driven decisions.' },
  { id: 'agent-010', name: 'Creative Writer', slug: 'creative-writer', description: 'Storytelling, poetry, marketing copy, and creative writing assistance for individuals and businesses.', category: 'Creative', creatorRole: 'etheros', status: 'live', pricingType: 'free', priceMonthly: 0, activationCount: 0, isEnabled: true, modelId: 'llama3.1:8b', systemPrompt: 'You are a creative writing assistant. Help with stories, poems, marketing copy, blog posts, and any creative writing project.' },
];

function loadAgents() {
  try {
    const raw = fs.readFileSync(AGENTS_FILE, 'utf8');
    return JSON.parse(raw);
  } catch {
    // Seed defaults on first load
    fs.mkdirSync(path.dirname(AGENTS_FILE), { recursive: true });
    fs.writeFileSync(AGENTS_FILE, JSON.stringify(DEFAULT_AGENTS, null, 2));
    return DEFAULT_AGENTS;
  }
}

function saveAgents(agents) {
  fs.mkdirSync(path.dirname(AGENTS_FILE), { recursive: true });
  fs.writeFileSync(AGENTS_FILE, JSON.stringify(agents, null, 2));
}

// GET /api/agents — list all agents
app.get('/api/agents', (req, res) => {
  const agents = loadAgents();
  // Attach live activation count from subscribers
  const subscribers = loadJSON(SUBSCRIBERS_FILE);
  const enriched = agents.map(a => ({
    ...a,
    activationCount: subscribers.filter(s => (s.activeAgentIds || []).includes(a.id)).length,
  }));
  res.json(enriched);
});

// GET /api/agents/browse — subscriber-facing: lists ISP-enabled agents with subscriber's activation status
// Called by the terminal after PIN auth. Token header: Authorization: Bearer <token>
app.get('/api/agents/browse', (req, res) => {
  // Parse subscriber from token
  const auth = req.headers.authorization || '';
  const token = auth.startsWith('Bearer ') ? auth.slice(7) : '';
  const subscriberId = parseToken(token);
  if (!subscriberId) return res.status(401).json({ error: 'Invalid or expired session' });

  const subscribers = loadJSON(SUBSCRIBERS_FILE);
  const sub = subscribers.find(s => s.id === subscriberId);
  if (!sub) return res.status(404).json({ error: 'Subscriber not found' });

  const agents = loadAgents();
  const activeIds = sub.activeAgentIds || [];
  const limit = PLAN_AGENT_LIMITS[sub.plan] || 3;

  // Return all ISP-enabled agents with activation state for this subscriber
  const browseable = agents
    .filter(a => a.isEnabled && a.status === 'live')
    .map(a => ({
      ...a,
      activated: activeIds.includes(a.id),
    }));

  res.json({
    agents: browseable,
    activeAgentIds: activeIds,
    limit,
    slotsUsed: activeIds.length,
    slotsRemaining: Math.max(0, limit - activeIds.length),
    plan: sub.plan,
  });
});

// GET /api/terminal/config — ISP branding + terminal config for subscriber screens
// Public (no auth needed) — used to brand the PIN screen before login
app.get('/api/terminal/config', (req, res) => {
  const s = loadSettings();
  // blacknutGamingPlans: array of plan slugs that have gaming access
  // defaults to ['professional','charter'] if not set
  const gamingPlans = Array.isArray(s.blacknutGamingPlans)
    ? s.blacknutGamingPlans
    : ['professional', 'charter'];
  res.json({
    ispName:            s.ispName      || 'EtherOS',
    accentColor:        s.accentColor  || '#00C2CB',
    logoUrl:            s.logoUrl      || null,
    welcomeTitle:       s.terminalWelcomeTitle  || null,
    welcomeBody:        s.terminalWelcomeBody   || null,
    supportPhone:       s.supportPhone  || null,
    supportEmail:       s.supportEmail  || null,
    blacknutEnabled:    !!s.blacknutEnabled,
    blacknutGamingPlans: gamingPlans,
  });
});

// POST /api/agents — create a new agent
app.post('/api/agents', (req, res) => {
  const { name, description, category, modelId, systemPrompt, pricingType, priceMonthly, notebookSources } = req.body;
  if (!name || !description) return res.status(400).json({ error: 'name and description are required' });
  const agents = loadAgents();
  const agent = {
    id: 'agent-' + require('crypto').randomUUID().slice(0, 8),
    name, description, category: category || 'Productivity',
    creatorRole: 'isp', status: 'live',
    pricingType: pricingType || 'free',
    priceMonthly: priceMonthly || 0,
    activationCount: 0, isEnabled: true,
    modelId: modelId || 'llama3.1:8b',
    systemPrompt: systemPrompt || '',
    slug: name.toLowerCase().replace(/[^a-z0-9]+/g, '-'),
    notebookSources: Array.isArray(notebookSources) ? notebookSources : [],
  };
  agents.push(agent);
  saveAgents(agents);
  res.status(201).json(agent);
});

// PATCH /api/agents/:id/toggle — ISP-level enable/disable
app.patch('/api/agents/:id/toggle', (req, res) => {
  const agents = loadAgents();
  const idx = agents.findIndex(a => a.id === req.params.id);
  if (idx < 0) return res.status(404).json({ error: 'Agent not found' });
  agents[idx].isEnabled = req.body.enabled ?? !agents[idx].isEnabled;
  saveAgents(agents);
  res.json(agents[idx]);
});

// PATCH /api/agents/:id — update agent fields
app.patch('/api/agents/:id', (req, res) => {
  const agents = loadAgents();
  const idx = agents.findIndex(a => a.id === req.params.id);
  if (idx < 0) return res.status(404).json({ error: 'Agent not found' });
  agents[idx] = { ...agents[idx], ...req.body, id: agents[idx].id, creatorRole: agents[idx].creatorRole };
  saveAgents(agents);
  res.json(agents[idx]);
});

// DELETE /api/agents/:id — remove an ISP-created agent
app.delete('/api/agents/:id', (req, res) => {
  const agents = loadAgents();
  const agent = agents.find(a => a.id === req.params.id);
  if (!agent) return res.status(404).json({ error: 'Agent not found' });
  if (agent.creatorRole !== 'isp') return res.status(403).json({ error: 'Cannot delete EtherOS agents' });
  saveAgents(agents.filter(a => a.id !== req.params.id));
  res.json({ ok: true });
});

// GET /api/subscribers/:id/agents — list this subscriber's active agents
app.get('/api/subscribers/:id/agents', (req, res) => {
  const subscribers = loadJSON(SUBSCRIBERS_FILE);
  const sub = subscribers.find(s => s.id === req.params.id);
  if (!sub) return res.status(404).json({ error: 'Subscriber not found' });
  const agents = loadAgents();
  const activeIds = sub.activeAgentIds || [];
  const active = agents.filter(a => activeIds.includes(a.id));
  res.json({ activeAgentIds: activeIds, agents: active, limit: PLAN_AGENT_LIMITS[sub.plan] || 3 });
});

// POST /api/subscribers/:id/agents/:agentId — activate an agent for a subscriber
app.post('/api/subscribers/:id/agents/:agentId', (req, res) => {
  const subscribers = loadJSON(SUBSCRIBERS_FILE);
  const idx = subscribers.findIndex(s => s.id === req.params.id);
  if (idx < 0) return res.status(404).json({ error: 'Subscriber not found' });

  const agents = loadAgents();
  const agent = agents.find(a => a.id === req.params.agentId);
  if (!agent) return res.status(404).json({ error: 'Agent not found' });
  if (!agent.isEnabled) return res.status(403).json({ error: 'Agent is not enabled by ISP' });

  const sub = subscribers[idx];
  const limit = PLAN_AGENT_LIMITS[sub.plan] || 3;
  const activeIds = sub.activeAgentIds || [];

  if (activeIds.includes(req.params.agentId)) {
    return res.status(409).json({ error: 'Agent already active for this subscriber' });
  }
  if (activeIds.length >= limit) {
    return res.status(403).json({ error: `Plan limit reached (${limit} agents max on ${sub.plan} plan)` });
  }

  sub.activeAgentIds = [...activeIds, req.params.agentId];
  sub.agentsActive = sub.activeAgentIds.length;
  sub.agents = sub.activeAgentIds.map(id => agents.find(a => a.id === id)?.name || id);
  subscribers[idx] = sub;
  saveJSON(SUBSCRIBERS_FILE, subscribers);
  res.json({ ok: true, subscriber: sub, activeAgentIds: sub.activeAgentIds });
});

// DELETE /api/subscribers/:id/agents/:agentId — deactivate an agent for a subscriber
app.delete('/api/subscribers/:id/agents/:agentId', (req, res) => {
  const subscribers = loadJSON(SUBSCRIBERS_FILE);
  const idx = subscribers.findIndex(s => s.id === req.params.id);
  if (idx < 0) return res.status(404).json({ error: 'Subscriber not found' });

  const sub = subscribers[idx];
  const agents = loadAgents();
  sub.activeAgentIds = (sub.activeAgentIds || []).filter(id => id !== req.params.agentId);
  sub.agentsActive = sub.activeAgentIds.length;
  sub.agents = sub.activeAgentIds.map(id => agents.find(a => a.id === id)?.name || id);
  subscribers[idx] = sub;
  saveJSON(SUBSCRIBERS_FILE, subscribers);
  res.json({ ok: true, subscriber: sub, activeAgentIds: sub.activeAgentIds });
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

// ── Subscriber Identity (terminal PIN auth) ───────────────────────────────────
// Subscribers are identified by a 6-digit PIN derived from their record.
// POST /api/subscribers/auth  { pin }  → { ok, subscriberId, name, plan, token }
// The token is a simple signed string: base64(subscriberId + "." + timestamp)
// — no external JWT library needed, validated by the next endpoint.

function makeToken(subscriberId) {
  const payload = `${subscriberId}.${Date.now()}`;
  return Buffer.from(payload).toString('base64url');
}

function parseToken(token) {
  try {
    const decoded = Buffer.from(token, 'base64url').toString('utf8');
    const [subscriberId, ts] = decoded.split('.');
    const age = Date.now() - parseInt(ts, 10);
    if (!subscriberId || age > 8 * 60 * 60 * 1000) return null; // 8h session
    return subscriberId;
  } catch { return null; }
}

function subscriberPin(sub) {
  // PIN = last 6 digits of subscriber id hash (deterministic, no storage needed)
  const hash = require('crypto').createHash('sha256').update(sub.id + sub.email).digest('hex');
  return hash.slice(-6).toUpperCase();
}

app.post('/api/subscribers/auth', (req, res) => {
  const { pin } = req.body || {};
  if (!pin) return res.status(400).json({ error: 'pin required' });
  const subscribers = loadJSON(SUBSCRIBERS_FILE);
  const sub = subscribers.find(s => subscriberPin(s) === String(pin).toUpperCase());
  if (!sub) return res.status(401).json({ error: 'PIN not recognised' });
  if (sub.status === 'suspended') return res.status(403).json({ error: 'Account suspended' });
  const token = makeToken(sub.id);
  res.json({ ok: true, subscriberId: sub.id, name: sub.name, plan: sub.plan, token });
});

// GET /api/subscribers/auth/pin/:id  — admin: look up PIN for a subscriber (for support)
app.get('/api/subscribers/auth/pin/:id', (req, res) => {
  const subscribers = loadJSON(SUBSCRIBERS_FILE);
  const sub = subscribers.find(s => s.id === req.params.id);
  if (!sub) return res.status(404).json({ error: 'Not found' });
  res.json({ pin: subscriberPin(sub) });
});

// GET /api/subscribers/me  — token → subscriber record
app.get('/api/subscribers/me', (req, res) => {
  const auth = (req.headers.authorization || '').replace('Bearer ', '');
  const subscriberId = parseToken(auth);
  if (!subscriberId) return res.status(401).json({ error: 'Invalid or expired token' });
  const subscribers = loadJSON(SUBSCRIBERS_FILE);
  const sub = subscribers.find(s => s.id === subscriberId);
  if (!sub) return res.status(404).json({ error: 'Subscriber not found' });
  res.json(sub);
});

// ── Cloud Services — Blacknut ─────────────────────────────────────────────────
//
// Settings fields (stored in isp-settings.json):
//   blacknutEnabled       — bool: show gaming tile to subscribers
//   blacknutApiKey        — string: Bearer token for Blacknut REST API
//   blacknutPartnerId     — string: Blacknut partner/ISP identifier
//   blacknutApiUrl        — string (optional): override default API base
//   blacknutGamingPlans   — string[]: which subscriber plans get gaming access
//                           defaults to ['professional','charter']
//
// Session flow:
//   1. Terminal POST /api/subscribers/:id/services/blacknut/session
//   2. Backend checks: enabled + plan entitlement + not suspended
//   3. STUB: returns { stub:true, launchUrl:'https://www.blacknut.com/en', expiresAt }
//   4. LIVE: calls Blacknut API, returns { stub:false, sessionId, launchUrl, expiresAt }
//   5. Terminal opens launchUrl in new tab; polls session status if needed

const BLACKNUT_DEFAULT_API = 'https://api.blacknut.com';

// Helper — check if a plan has gaming access
function planHasGaming(settings, plan) {
  const gamingPlans = Array.isArray(settings.blacknutGamingPlans)
    ? settings.blacknutGamingPlans
    : ['professional', 'charter'];
  return gamingPlans.includes(plan);
}

// POST /api/subscribers/:id/services/blacknut/session
// Creates (or stubs) a Blacknut gaming session for the subscriber.
app.post('/api/subscribers/:id/services/blacknut/session', async (req, res) => {
  const settings = loadSettings();

  // 1. Blacknut must be enabled at the ISP level
  if (!settings.blacknutEnabled) {
    return res.status(403).json({ error: 'Gaming is not enabled for this ISP' });
  }

  // 2. Validate subscriber exists + is active
  const subscribers = loadJSON(SUBSCRIBERS_FILE);
  const sub = subscribers.find(s => s.id === req.params.id);
  if (!sub) return res.status(404).json({ error: 'Subscriber not found' });
  if (sub.status === 'suspended') return res.status(403).json({ error: 'Account suspended' });

  // 3. Plan entitlement check
  if (!planHasGaming(settings, sub.plan)) {
    return res.status(403).json({
      error: 'Gaming not included in your plan',
      plan: sub.plan,
      requiredPlans: Array.isArray(settings.blacknutGamingPlans)
        ? settings.blacknutGamingPlans
        : ['professional', 'charter'],
    });
  }

  // ── STUB MODE (no API keys yet) ──────────────────────────────────────────
  if (!settings.blacknutApiKey || !settings.blacknutPartnerId) {
    const expiresAt = new Date(Date.now() + 4 * 60 * 60 * 1000).toISOString();
    return res.json({
      ok: true,
      stub: true,
      sessionId: 'stub-' + Date.now(),
      launchUrl: 'https://www.blacknut.com/en',
      expiresAt,
      plan: sub.plan,
      message: 'Blacknut API keys not yet configured — returning stub session',
    });
  }

  // ── LIVE MODE (once keys are in settings) ────────────────────────────────
  try {
    const apiBase = (settings.blacknutApiUrl || BLACKNUT_DEFAULT_API).replace(/\/$/, '');
    const response = await fetch(`${apiBase}/v1/sessions`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'X-Partner-Id': settings.blacknutPartnerId,
        'Authorization': `Bearer ${settings.blacknutApiKey}`,
      },
      body: JSON.stringify({
        partnerId:      settings.blacknutPartnerId,
        externalUserId: sub.id,
        plan:           sub.plan,
        userEmail:      sub.email,
        displayName:    sub.name,
      }),
    });

    if (!response.ok) {
      const err = await response.text();
      return res.status(502).json({ error: `Blacknut API error: ${response.status}`, detail: err });
    }

    const data = await response.json();
    const sessionId = data.sessionId || data.id || data.session_id || null;
    const launchUrl = data.launchUrl || data.url || data.sessionUrl;
    const expiresAt = data.expiresAt || data.expires_at || null;

    res.json({ ok: true, stub: false, sessionId, launchUrl, expiresAt, plan: sub.plan });
  } catch (err) {
    res.status(502).json({ error: 'Failed to reach Blacknut API', detail: String(err) });
  }
});

// GET /api/subscribers/:id/services/blacknut/session/:sessionId
// Poll a live session's status (stub always returns 'active').
app.get('/api/subscribers/:id/services/blacknut/session/:sessionId', async (req, res) => {
  const settings = loadSettings();
  const { sessionId } = req.params;

  // Stub session
  if (!settings.blacknutApiKey || !settings.blacknutPartnerId || sessionId.startsWith('stub-')) {
    return res.json({ sessionId, status: 'active', stub: true });
  }

  try {
    const apiBase = (settings.blacknutApiUrl || BLACKNUT_DEFAULT_API).replace(/\/$/, '');
    const r = await fetch(`${apiBase}/v1/sessions/${sessionId}`, {
      headers: {
        'X-Partner-Id': settings.blacknutPartnerId,
        'Authorization': `Bearer ${settings.blacknutApiKey}`,
      },
    });
    if (!r.ok) return res.status(r.status).json({ error: 'Session not found or expired' });
    const data = await r.json();
    res.json({ sessionId, status: data.status || 'active', expiresAt: data.expiresAt || data.expires_at, stub: false });
  } catch (err) {
    res.status(502).json({ error: 'Failed to reach Blacknut API', detail: String(err) });
  }
});

// GET /api/services/blacknut/status — admin: check if Blacknut is configured + reachable
app.get('/api/services/blacknut/status', async (req, res) => {
  const settings = loadSettings();
  if (!settings.blacknutEnabled) return res.json({ enabled: false, configured: false });
  if (!settings.blacknutApiKey || !settings.blacknutPartnerId) {
    return res.json({
      enabled: true,
      configured: false,
      message: 'API keys not set — running in stub mode',
      gamingPlans: Array.isArray(settings.blacknutGamingPlans) ? settings.blacknutGamingPlans : ['professional','charter'],
    });
  }
  try {
    const apiBase = (settings.blacknutApiUrl || BLACKNUT_DEFAULT_API).replace(/\/$/, '');
    const r = await fetch(`${apiBase}/v1/partner/${settings.blacknutPartnerId}/status`, {
      headers: { 'Authorization': `Bearer ${settings.blacknutApiKey}` },
    });
    res.json({
      enabled: true,
      configured: true,
      reachable: r.ok,
      httpStatus: r.status,
      gamingPlans: Array.isArray(settings.blacknutGamingPlans) ? settings.blacknutGamingPlans : ['professional','charter'],
    });
  } catch (err) {
    res.json({ enabled: true, configured: true, reachable: false, error: String(err) });
  }
});

// ── Persistent Chat History ────────────────────────────────────────────────────
//
// Storage layout (per-tenant):
//   ${DATA_DIR}/chats/${subscriberId}/${agentId}.json
//
// Each file is an array of messages:
//   [{ role, content, timestamp }, ...]
//
// Endpoints:
//   GET    /api/subscribers/:id/chats              → list agents with recent chat
//   GET    /api/subscribers/:id/chats/:agentId     → last 50 messages for agent
//   POST   /api/subscribers/:id/chats/:agentId     → append message { role, content }
//   DELETE /api/subscribers/:id/chats/:agentId     → clear chat for agent
//
// All endpoints require Bearer token auth (parseToken).
// The :id in the URL must match the token's subscriberId.

const MAX_HISTORY = 50;

function chatFile(subscriberId, agentId) {
  return path.join(DATA_DIR, 'chats', subscriberId, `${agentId}.json`);
}

function loadChatHistory(subscriberId, agentId) {
  const file = chatFile(subscriberId, agentId);
  if (!fs.existsSync(file)) return [];
  try { return JSON.parse(fs.readFileSync(file, 'utf8')); } catch { return []; }
}

function saveChatHistory(subscriberId, agentId, messages) {
  const dir = path.join(DATA_DIR, 'chats', subscriberId);
  if (!fs.existsSync(dir)) fs.mkdirSync(dir, { recursive: true });
  fs.writeFileSync(chatFile(subscriberId, agentId), JSON.stringify(messages, null, 2));
}

// ── Auth middleware check shared by all 4 chat endpoints ──────────────────────
function requireSubscriberToken(req, res) {
  const auth = (req.headers.authorization || '').replace('Bearer ', '');
  const tokenSubId = parseToken(auth);
  if (!tokenSubId) { res.status(401).json({ error: 'Invalid or expired token' }); return null; }
  if (tokenSubId !== req.params.id) { res.status(403).json({ error: 'Forbidden' }); return null; }
  return tokenSubId;
}

// GET /api/subscribers/:id/chats — list all agents with recent chat activity
app.get('/api/subscribers/:id/chats', (req, res) => {
  const subId = requireSubscriberToken(req, res);
  if (!subId) return;

  const chatsDir = path.join(DATA_DIR, 'chats', subId);
  if (!fs.existsSync(chatsDir)) return res.json({ conversations: [] });

  const agents = loadJSON(AGENTS_FILE);
  const files = fs.readdirSync(chatsDir).filter(f => f.endsWith('.json'));

  const conversations = files.map(file => {
    const agentId = file.replace('.json', '');
    const messages = loadChatHistory(subId, agentId);
    const last = messages[messages.length - 1] || null;
    const agent = agents.find(a => a.id === agentId);
    return {
      agentId,
      agentName: agent?.name || agentId,
      agentCategory: agent?.category || null,
      messageCount: messages.length,
      lastMessage: last ? {
        role: last.role,
        content: last.content.slice(0, 120),
        timestamp: last.timestamp,
      } : null,
    };
  }).filter(c => c.lastMessage);

  // Sort by last message timestamp descending
  conversations.sort((a, b) =>
    new Date(b.lastMessage.timestamp).getTime() - new Date(a.lastMessage.timestamp).getTime()
  );

  res.json({ conversations });
});

// GET /api/subscribers/:id/chats/:agentId — load last 50 messages
app.get('/api/subscribers/:id/chats/:agentId', (req, res) => {
  const subId = requireSubscriberToken(req, res);
  if (!subId) return;

  const all = loadChatHistory(subId, req.params.agentId);
  const messages = all.slice(-MAX_HISTORY);
  res.json({ messages, total: all.length });
});

// POST /api/subscribers/:id/chats/:agentId — append a message { role, content }
app.post('/api/subscribers/:id/chats/:agentId', (req, res) => {
  const subId = requireSubscriberToken(req, res);
  if (!subId) return;

  const { role, content } = req.body || {};
  if (!role || !content) return res.status(400).json({ error: 'role and content required' });
  if (!['user', 'assistant'].includes(role)) return res.status(400).json({ error: 'role must be user or assistant' });

  const messages = loadChatHistory(subId, req.params.agentId);
  const newMsg = { role, content, timestamp: new Date().toISOString() };
  messages.push(newMsg);

  // Keep only the last MAX_HISTORY * 2 messages on disk (trim on write)
  const trimmed = messages.slice(-(MAX_HISTORY * 2));
  saveChatHistory(subId, req.params.agentId, trimmed);

  res.json({ ok: true, message: newMsg, total: trimmed.length });
});

// DELETE /api/subscribers/:id/chats/:agentId — clear all chat history for an agent
app.delete('/api/subscribers/:id/chats/:agentId', (req, res) => {
  const subId = requireSubscriberToken(req, res);
  if (!subId) return;

  const file = chatFile(subId, req.params.agentId);
  if (fs.existsSync(file)) fs.unlinkSync(file);
  res.json({ ok: true });
});

// ============================================================
//  Sprint 4I — Marketing Console Core
//  Roles: isp_admin (full CRUD), isp_marketer (own campaigns),
//         isp_manager (view-only + marketing, same as marketer)
//
//  Data files (JSON, same DATA_DIR pattern):
//    $DATA_DIR/marketing-campaigns.json
//    $DATA_DIR/marketing-pages.json
//    $DATA_DIR/marketing-users.json  ← { marketerUsers: [{id,name,email,token}] }
//
//  Auth:
//    Admin endpoints → x-admin-token header == settings.adminToken (or any truthy)
//    Marketer/Manager → Authorization: Bearer <marketerToken>
//    Public page view → no auth (GET /api/marketing/pages/:slug/view)
// ============================================================

const CAMPAIGNS_FILE      = `${DATA_DIR}/marketing-campaigns.json`;
const MARKETING_PAGES_FILE = `${DATA_DIR}/marketing-pages.json`;
const MKTG_USERS_FILE     = `${DATA_DIR}/marketing-users.json`;

// ── Helpers ───────────────────────────────────────────────────────────────────

function loadCampaigns() {
  try { return JSON.parse(fs.readFileSync(CAMPAIGNS_FILE, 'utf8')); } catch { return []; }
}
function saveCampaigns(d) {
  fs.mkdirSync(path.dirname(CAMPAIGNS_FILE), { recursive: true });
  fs.writeFileSync(CAMPAIGNS_FILE, JSON.stringify(d, null, 2));
}

function loadMktgPages() {
  try { return JSON.parse(fs.readFileSync(MARKETING_PAGES_FILE, 'utf8')); } catch { return []; }
}
function saveMktgPages(d) {
  fs.mkdirSync(path.dirname(MARKETING_PAGES_FILE), { recursive: true });
  fs.writeFileSync(MARKETING_PAGES_FILE, JSON.stringify(d, null, 2));
}

function loadMktgUsers() {
  try { return JSON.parse(fs.readFileSync(MKTG_USERS_FILE, 'utf8')); } catch { return { marketerUsers: [] }; }
}
function saveMktgUsers(d) {
  fs.mkdirSync(path.dirname(MKTG_USERS_FILE), { recursive: true });
  fs.writeFileSync(MKTG_USERS_FILE, JSON.stringify(d, null, 2));
}

// Resolve caller role: 'admin' | 'marketer' | null
function resolveMktgRole(req) {
  // Admin token check (x-admin-token header, or settings has no adminToken set → dev mode open)
  const adminHeader = req.headers['x-admin-token'] || '';
  const s = loadSettings();
  if (!s.adminToken || adminHeader === s.adminToken) return 'admin';

  // Marketer / Manager token
  const bearer = (req.headers.authorization || '').replace('Bearer ', '').trim();
  if (!bearer) return null;
  const mu = loadMktgUsers();
  const user = (mu.marketerUsers || []).find(u => u.token === bearer && u.active !== false);
  if (user) return 'marketer';

  return null;
}

function requireMktgAccess(req, res) {
  const role = resolveMktgRole(req);
  if (!role) { res.status(401).json({ error: 'Marketing auth required' }); return null; }
  return role;
}

function mktgId() {
  return Date.now().toString(36) + Math.random().toString(36).slice(2, 7);
}

// ── Marketer User Management ──────────────────────────────────────────────────

// GET /api/marketing/users — list marketer/manager users (admin only)
app.get('/api/marketing/users', (req, res) => {
  if (resolveMktgRole(req) !== 'admin') return res.status(403).json({ error: 'Admin only' });
  const mu = loadMktgUsers();
  res.json(mu.marketerUsers || []);
});

// POST /api/marketing/users — create marketer user (admin only)
app.post('/api/marketing/users', (req, res) => {
  if (resolveMktgRole(req) !== 'admin') return res.status(403).json({ error: 'Admin only' });
  const { name, email, role: userRole } = req.body || {};
  if (!name || !email) return res.status(400).json({ error: 'name and email required' });
  const mu = loadMktgUsers();
  const newUser = {
    id: mktgId(),
    name,
    email,
    role: userRole || 'marketer', // 'marketer' | 'manager'
    token: require('crypto').randomBytes(24).toString('hex'),
    active: true,
    createdAt: new Date().toISOString(),
  };
  mu.marketerUsers = [...(mu.marketerUsers || []), newUser];
  saveMktgUsers(mu);
  res.json(newUser);
});

// DELETE /api/marketing/users/:id — remove marketer user (admin only)
app.delete('/api/marketing/users/:id', (req, res) => {
  if (resolveMktgRole(req) !== 'admin') return res.status(403).json({ error: 'Admin only' });
  const mu = loadMktgUsers();
  mu.marketerUsers = (mu.marketerUsers || []).filter(u => u.id !== req.params.id);
  saveMktgUsers(mu);
  res.json({ ok: true });
});

// GET /api/marketing/me — resolve current caller's identity
app.get('/api/marketing/me', (req, res) => {
  const role = resolveMktgRole(req);
  if (!role) return res.status(401).json({ error: 'Unauthorized' });
  if (role === 'admin') return res.json({ role: 'admin', name: 'Admin' });
  const bearer = (req.headers.authorization || '').replace('Bearer ', '').trim();
  const mu = loadMktgUsers();
  const user = (mu.marketerUsers || []).find(u => u.token === bearer);
  res.json({ role: user?.role || 'marketer', name: user?.name || 'Marketer', id: user?.id });
});

// ── Campaigns ─────────────────────────────────────────────────────────────────
//
//  Campaign shape:
//  {
//    id, name, type ('social'|'email'|'page'), status ('draft'|'published'|'scheduled'|'archived'),
//    agentId, agentName, agentCategory, agentImageUrl,
//    headline, body, ctaText, ctaUrl, heroImageUrl,
//    targetPlans (['personal','professional','charter']),
//    scheduledAt (ISO string | null),
//    createdBy ('admin' | marketerUserId),
//    createdAt, updatedAt
//  }

// GET /api/marketing/campaigns
app.get('/api/marketing/campaigns', (req, res) => {
  const role = requireMktgAccess(req, res);
  if (!role) return;
  let campaigns = loadCampaigns();

  // Filter by status if provided
  if (req.query.status) {
    campaigns = campaigns.filter(c => c.status === req.query.status);
  }
  // Filter by type if provided
  if (req.query.type) {
    campaigns = campaigns.filter(c => c.type === req.query.type);
  }
  res.json(campaigns);
});

// POST /api/marketing/campaigns
app.post('/api/marketing/campaigns', (req, res) => {
  const role = requireMktgAccess(req, res);
  if (!role) return;

  const {
    name, type, agentId, agentName, agentCategory, agentImageUrl,
    headline, body, ctaText, ctaUrl, heroImageUrl,
    targetPlans, scheduledAt, status,
  } = req.body || {};

  if (!name) return res.status(400).json({ error: 'name is required' });

  // Resolve createdBy
  let createdBy = 'admin';
  if (role !== 'admin') {
    const bearer = (req.headers.authorization || '').replace('Bearer ', '').trim();
    const mu = loadMktgUsers();
    const user = (mu.marketerUsers || []).find(u => u.token === bearer);
    createdBy = user?.id || 'marketer';
  }

  const campaigns = loadCampaigns();
  const newCampaign = {
    id: mktgId(),
    name,
    type: type || 'social',
    status: status || 'draft',
    agentId: agentId || null,
    agentName: agentName || null,
    agentCategory: agentCategory || null,
    agentImageUrl: agentImageUrl || null,
    headline: headline || '',
    body: body || '',
    ctaText: ctaText || 'Try it now',
    ctaUrl: ctaUrl || '',
    heroImageUrl: heroImageUrl || agentImageUrl || null,
    targetPlans: targetPlans || ['personal', 'professional', 'charter'],
    scheduledAt: scheduledAt || null,
    createdBy,
    createdAt: new Date().toISOString(),
    updatedAt: new Date().toISOString(),
  };

  campaigns.push(newCampaign);
  saveCampaigns(campaigns);
  res.status(201).json(newCampaign);
});

// PATCH /api/marketing/campaigns/:id
app.patch('/api/marketing/campaigns/:id', (req, res) => {
  const role = requireMktgAccess(req, res);
  if (!role) return;

  const campaigns = loadCampaigns();
  const idx = campaigns.findIndex(c => c.id === req.params.id);
  if (idx < 0) return res.status(404).json({ error: 'Campaign not found' });

  // Marketers can only edit their own campaigns
  if (role !== 'admin') {
    const bearer = (req.headers.authorization || '').replace('Bearer ', '').trim();
    const mu = loadMktgUsers();
    const user = (mu.marketerUsers || []).find(u => u.token === bearer);
    if (campaigns[idx].createdBy !== user?.id) {
      return res.status(403).json({ error: 'You can only edit your own campaigns' });
    }
  }

  const updated = {
    ...campaigns[idx],
    ...req.body,
    id: campaigns[idx].id,       // immutable
    createdBy: campaigns[idx].createdBy, // immutable
    createdAt: campaigns[idx].createdAt, // immutable
    updatedAt: new Date().toISOString(),
  };
  campaigns[idx] = updated;
  saveCampaigns(campaigns);
  res.json(updated);
});

// DELETE /api/marketing/campaigns/:id
app.delete('/api/marketing/campaigns/:id', (req, res) => {
  const role = requireMktgAccess(req, res);
  if (!role) return;

  const campaigns = loadCampaigns();
  const idx = campaigns.findIndex(c => c.id === req.params.id);
  if (idx < 0) return res.status(404).json({ error: 'Campaign not found' });

  // Marketers can only delete their own
  if (role !== 'admin') {
    const bearer = (req.headers.authorization || '').replace('Bearer ', '').trim();
    const mu = loadMktgUsers();
    const user = (mu.marketerUsers || []).find(u => u.token === bearer);
    if (campaigns[idx].createdBy !== user?.id) {
      return res.status(403).json({ error: 'You can only delete your own campaigns' });
    }
  }

  campaigns.splice(idx, 1);
  saveCampaigns(campaigns);
  res.json({ ok: true });
});

// ── Marketing Pages ───────────────────────────────────────────────────────────
//
//  Page shape:
//  {
//    id, slug, title, heroImageUrl, headline, bodyHtml,
//    features ([{icon,text}]),
//    ctaText, ctaUrl (defaults to /#/terminal),
//    agentId, agentName,
//    published (bool),
//    createdAt, updatedAt
//  }

// GET /api/marketing/pages
app.get('/api/marketing/pages', (req, res) => {
  const role = requireMktgAccess(req, res);
  if (!role) return;
  res.json(loadMktgPages());
});

// GET /api/marketing/pages/:slug/view — PUBLIC (no auth, renders page data)
app.get('/api/marketing/pages/:slug/view', (req, res) => {
  const pages = loadMktgPages();
  const page = pages.find(p => p.slug === req.params.slug && p.published);
  if (!page) return res.status(404).json({ error: 'Page not found or not published' });
  const s = loadSettings();
  res.json({ ...page, ispName: s.ispName || 'EtherOS', accentColor: s.accentColor || '#00C2CB' });
});

// POST /api/marketing/pages
app.post('/api/marketing/pages', (req, res) => {
  const role = requireMktgAccess(req, res);
  if (!role) return;

  const { slug, title, heroImageUrl, headline, bodyHtml, features, ctaText, ctaUrl, agentId, agentName, published } = req.body || {};
  if (!slug || !title) return res.status(400).json({ error: 'slug and title required' });

  const pages = loadMktgPages();
  if (pages.find(p => p.slug === slug)) return res.status(409).json({ error: 'Slug already exists' });

  const newPage = {
    id: mktgId(),
    slug,
    title,
    heroImageUrl: heroImageUrl || null,
    headline: headline || title,
    bodyHtml: bodyHtml || '',
    features: features || [],
    ctaText: ctaText || 'Try it now',
    ctaUrl: ctaUrl || '/#/terminal',
    agentId: agentId || null,
    agentName: agentName || null,
    published: published || false,
    createdAt: new Date().toISOString(),
    updatedAt: new Date().toISOString(),
  };
  pages.push(newPage);
  saveMktgPages(pages);
  res.status(201).json(newPage);
});

// PATCH /api/marketing/pages/:id
app.patch('/api/marketing/pages/:id', (req, res) => {
  const role = requireMktgAccess(req, res);
  if (!role) return;

  const pages = loadMktgPages();
  const idx = pages.findIndex(p => p.id === req.params.id);
  if (idx < 0) return res.status(404).json({ error: 'Page not found' });

  // Slug uniqueness check if changing
  if (req.body.slug && req.body.slug !== pages[idx].slug) {
    if (pages.find(p => p.slug === req.body.slug)) {
      return res.status(409).json({ error: 'Slug already exists' });
    }
  }

  pages[idx] = {
    ...pages[idx],
    ...req.body,
    id: pages[idx].id,
    createdAt: pages[idx].createdAt,
    updatedAt: new Date().toISOString(),
  };
  saveMktgPages(pages);
  res.json(pages[idx]);
});

// DELETE /api/marketing/pages/:id
app.delete('/api/marketing/pages/:id', (req, res) => {
  const role = requireMktgAccess(req, res);
  if (!role) return;

  const pages = loadMktgPages();
  const idx = pages.findIndex(p => p.id === req.params.id);
  if (idx < 0) return res.status(404).json({ error: 'Page not found' });

  pages.splice(idx, 1);
  saveMktgPages(pages);
  res.json({ ok: true });
});

// ── End Sprint 4I ─────────────────────────────────────────────────────────────
