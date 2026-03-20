'use strict';
const { sendPinWelcomeEmail } = require('./email');
/**
 * routes/billing.js — ISP-level Stripe billing, tenant provisioning
 */

const { Router } = require('express');
const fs   = require('fs');
const path = require('path');
const { getDb } = require('../db');

const STRIPE_PLANS = [
  { id:'starter', name:'Starter', description:'Perfect for rural ISPs getting started with AI-powered terminals.', priceMonthly:29900, terminalLimit:25, subscriberLimit:200, features:['Up to 25 EtherOS terminals','Up to 200 active subscribers','All free marketplace agents','Basic analytics dashboard','Email support'], stripePriceId:'price_1TBFYVERnCKuXiJafhCHg3I7', stripePriceIdTest:'price_1TBFYVERnCKuXiJafhCHg3I7' },
  { id:'growth',  name:'Growth',  description:'For expanding ISPs with growing subscriber bases and premium agents.', priceMonthly:79900, terminalLimit:100, subscriberLimit:1000, features:['Up to 100 EtherOS terminals','Up to 1,000 active subscribers','All marketplace agents including premium','Full revenue analytics + export','Priority support + SLA','White-label branding'], stripePriceId:'price_1TBFZEERnCKuXiJaCrEBy0JN', stripePriceIdTest:'price_1TBFZEERnCKuXiJaCrEBy0JN' },
  { id:'enterprise', name:'Enterprise', description:'Unlimited scale for large regional ISPs and multi-state operators.', priceMonthly:199900, terminalLimit:9999, subscriberLimit:9999, features:['Unlimited EtherOS terminals','Unlimited active subscribers','All agents + first access to new releases','Custom agent development','Dedicated account manager','Custom integrations + API access'], stripePriceId:'price_1TBFZsERnCKuXiJaSteuC2TV', stripePriceIdTest:'price_1TBFZsERnCKuXiJaSteuC2TV' },
];

async function syncSubscription(db, stripe, subscriptionId) {
  const sub = await stripe.subscriptions.retrieve(subscriptionId, { expand: ['default_payment_method','items.data.price'] });
  const priceId = sub.items.data[0]?.price?.id;
  const plan = STRIPE_PLANS.find(p => p.stripePriceId === priceId || p.stripePriceIdTest === priceId);
  db.prepare(`UPDATE billing_state SET subscription_id=@sub_id,plan_id=@plan_id,status=@status,
    current_period_end=@cpe,cancel_at_period_end=@cape,trial_end=@trial,
    payment_method_last4=@last4,payment_method_brand=@brand WHERE id=1`).run({
    sub_id: sub.id, plan_id: plan?.id||null, status: sub.status,
    cpe: new Date(sub.current_period_end * 1000).toISOString(),
    cape: sub.cancel_at_period_end ? 1 : 0,
    trial: sub.trial_end ? new Date(sub.trial_end * 1000).toISOString() : null,
    last4: sub.default_payment_method?.card?.last4 || null,
    brand: sub.default_payment_method?.card?.brand || null,
  });
}

async function fetchInvoices(stripe, customerId) {
  try {
    const list = await stripe.invoices.list({ customer: customerId, limit: 12 });
    return list.data.map(inv => ({ id:inv.id, date:new Date(inv.created*1000).toISOString(), amount:inv.amount_paid||inv.amount_due, status:inv.status, pdfUrl:inv.invoice_pdf, hostedUrl:inv.hosted_invoice_url }));
  } catch { return []; }
}

function billingStateFromRow(r) {
  if (!r) return { customerId:null, subscriptionId:null, planId:null, status:'none', currentPeriodEnd:null, cancelAtPeriodEnd:false, trialEnd:null, paymentMethodLast4:null, paymentMethodBrand:null };
  return { customerId:r.customer_id, subscriptionId:r.subscription_id, planId:r.plan_id, status:r.status||'none', currentPeriodEnd:r.current_period_end, cancelAtPeriodEnd:!!r.cancel_at_period_end, trialEnd:r.trial_end, paymentMethodLast4:r.payment_method_last4, paymentMethodBrand:r.payment_method_brand };
}

module.exports = function billingRouter(DATA_DIR, loadSettings, getStripe, portalUrl) {
  const router = Router();
  function db() { return getDb(DATA_DIR); }
  function bs()  { return billingStateFromRow(db().prepare('SELECT * FROM billing_state WHERE id=1').get()); }

  router.get('/', async (req, res) => {
    const stripe = getStripe();
    const s = loadSettings();
    const hasStripeKey = !!(s.stripeKey || '').trim();
    if (!stripe) return res.json({ ...bs(), status:'none', customerId:null, invoices:[], hasStripeKey });
    try {
      const state = bs();
      const d = db();
      if (state.subscriptionId) await syncSubscription(d, stripe, state.subscriptionId);
      const fresh = bs();
      const invoices = fresh.customerId ? await fetchInvoices(stripe, fresh.customerId) : [];
      res.json({ ...fresh, invoices, hasStripeKey: true });
    } catch (err) { res.status(500).json({ error: String(err) }); }
  });

  router.get('/plans', (req, res) => res.json(STRIPE_PLANS));

  router.post('/checkout', async (req, res) => {
    const stripe = getStripe();
    if (!stripe) return res.status(400).json({ error: 'Stripe not configured. Add your Stripe secret key in Settings.' });
    const { planId, successUrl, cancelUrl } = req.body;
    const plan = STRIPE_PLANS.find(p => p.id === planId);
    if (!plan) return res.status(400).json({ error: 'Unknown plan' });
    const settings = loadSettings();
    const priceId = settings.stripeKey?.startsWith('sk_test_') ? plan.stripePriceIdTest : plan.stripePriceId;
    try {
      const state = bs();
      const params = {
        mode: 'subscription',
        line_items: [{ price: priceId, quantity: 1 }],
        subscription_data: { trial_period_days: 14 },
        success_url: (() => { const base = successUrl || portalUrl('/isp-portal/#/billing?status=success'); return base + (base.includes('?') ? '&' : '?') + 'session_id={CHECKOUT_SESSION_ID}'; })(),
        cancel_url: cancelUrl || portalUrl('/isp-portal/#/billing?status=canceled'),
      };
      if (state.customerId) params.customer = state.customerId;
      const session = await stripe.checkout.sessions.create(params);
      if (!state.customerId && session.customer) {
        db().prepare('UPDATE billing_state SET customer_id=? WHERE id=1').run(session.customer);
      }
      res.json({ url: session.url });
    } catch (err) { res.status(500).json({ error: String(err) }); }
  });

  router.get('/sync-session', async (req, res) => {
    const stripe = getStripe();
    if (!stripe) return res.json({ ok: false });
    const { session_id } = req.query;
    if (!session_id) return res.json({ ok: false, error: 'No session_id' });
    try {
      const session = await stripe.checkout.sessions.retrieve(session_id, { expand: ['subscription','customer'] });
      const d = db();
      if (session.customer) {
        const cid = typeof session.customer === 'string' ? session.customer : session.customer.id;
        d.prepare('UPDATE billing_state SET customer_id=? WHERE id=1').run(cid);
      }
      if (session.subscription) {
        const sub = typeof session.subscription === 'string' ? await stripe.subscriptions.retrieve(session.subscription) : session.subscription;
        const priceId = sub.items?.data?.[0]?.price?.id;
        const plan = STRIPE_PLANS.find(p => p.stripePriceId === priceId || p.stripePriceIdTest === priceId);
        d.prepare(`UPDATE billing_state SET subscription_id=?,plan_id=?,status=?,current_period_end=?,trial_end=?,cancel_at_period_end=? WHERE id=1`)
          .run(sub.id, plan?.id||null, sub.status, new Date(sub.current_period_end*1000).toISOString(), sub.trial_end ? new Date(sub.trial_end*1000).toISOString() : null, sub.cancel_at_period_end ? 1 : 0);
      }
      const fresh = bs();
      res.json({ ok: true, status: fresh.status, planId: fresh.planId });
    } catch (err) { res.json({ ok: false, error: String(err) }); }
  });

  router.post('/portal', async (req, res) => {
    const stripe = getStripe();
    if (!stripe) return res.status(400).json({ error: 'Stripe not configured' });
    const state = bs();
    if (!state.customerId) return res.status(400).json({ error: 'No active subscription' });
    try {
      const session = await stripe.billingPortal.sessions.create({ customer: state.customerId, return_url: req.body.returnUrl || portalUrl('/isp-portal/#/billing') });
      res.json({ url: session.url });
    } catch (err) { res.status(500).json({ error: String(err) }); }
  });

  // ── Stripe webhook ────────────────────────────────────────────────────────
  // NOTE: raw body parsing is registered in server.js before express.json()
  router.post('/webhook', async (req, res) => {
    const stripe = getStripe();
    if (!stripe) return res.status(400).json({ error: 'Stripe not configured' });
    const settings = loadSettings();
    const sig    = req.headers['stripe-signature'];
    // Prefer env var; fall back to settings UI value
    const secret = (process.env.STRIPE_WEBHOOK_SECRET || settings.stripeWebhookSecret || '').trim();
    if (!secret) return res.status(400).json({ error: 'Webhook secret not configured — add STRIPE_WEBHOOK_SECRET env var or set in Settings' });
    if (!sig)    return res.status(400).json({ error: 'Missing stripe-signature header' });
    let event;
    try {
      event = stripe.webhooks.constructEvent(req.body, sig, secret);
    } catch { return res.status(400).json({ error: 'Webhook signature verification failed' }); }
    try {
      const d = db();
      switch (event.type) {
        case 'customer.subscription.created':
        case 'customer.subscription.updated':
        case 'customer.subscription.deleted': {
          const subObj = event.data.object;
          const state = bs();
          if (subObj.id === state.subscriptionId || !state.subscriptionId) {
            d.prepare('UPDATE billing_state SET subscription_id=?,customer_id=? WHERE id=1').run(subObj.id, subObj.customer);
            await syncSubscription(d, stripe, subObj.id);
          }
          // Sync subscriber record
          const subRow = d.prepare('SELECT * FROM subscribers WHERE stripe_customer_id=?').get(subObj.customer);
          if (subRow) {
            const newStatus = subObj.status === 'active' ? 'active' : subObj.status === 'past_due' ? 'past_due' : subObj.status === 'canceled' ? 'canceled' : subRow.billing_status;
            d.prepare('UPDATE subscribers SET billing_status=?,stripe_subscription_id=?,current_period_end=?,cancel_at_period_end=? WHERE id=?')
              .run(event.type === 'customer.subscription.deleted' ? 'canceled' : newStatus, subObj.id, subObj.current_period_end ? new Date(subObj.current_period_end*1000).toISOString() : null, subObj.cancel_at_period_end ? 1 : 0, subRow.id);
          }
          break;
        }
        case 'invoice.payment_failed': {
          const inv = event.data.object;
          d.prepare("UPDATE subscribers SET billing_status='past_due' WHERE stripe_customer_id=?").run(inv.customer);
          break;
        }
        case 'checkout.session.completed': {
          const sess = event.data.object;
          if (sess.subscription) {
            d.prepare('UPDATE billing_state SET customer_id=?,subscription_id=? WHERE id=1').run(sess.customer, sess.subscription);
            await syncSubscription(d, stripe, sess.subscription);
          }
          if (sess.metadata?.subscriberId) {
            d.prepare("UPDATE subscribers SET stripe_customer_id=COALESCE(@cid,stripe_customer_id),stripe_subscription_id=COALESCE(@sid,stripe_subscription_id),billing_status='active',plan=COALESCE(@plan,plan) WHERE id=@id")
              .run({ cid:sess.customer||null, sid:sess.subscription||null, plan:sess.metadata.plan||null, id:sess.metadata.subscriberId });
            // Send welcome + PIN email now that billing_status is active
            try {
              const { createHash } = require('crypto');
              const { subscriberFromRow } = require('../db');
              const subRow = d.prepare('SELECT * FROM subscribers WHERE id=?').get(sess.metadata.subscriberId);
              if (subRow) {
                const sub = subscriberFromRow(subRow);
                const pin = createHash('sha256').update(sub.id + sub.email).digest('hex').slice(-6).toUpperCase();
                const settings = loadSettings();
                sendPinWelcomeEmail({
                  subscriber: sub, pin,
                  ispName: settings.ispName || 'EtherOS',
                  terminalUrl: `https://${settings.domain || 'edge.etheros.ai'}/isp-portal/#/terminal`,
                  loadSettings,
                }).catch(e => console.error('[webhook] PIN email failed:', e));
              }
            } catch (emailErr) { console.error('[webhook] PIN email error:', emailErr); }
          }
          // Auto-provision ISP tenant
          if (sess.metadata?.provision_type === 'new_isp' && sess.metadata?.isp_slug) {
            const m = sess.metadata;
            const slug = m.isp_slug.replace(/[^a-z0-9-]/g, '-');
            const tenantDir = `/app/data/${slug}`;
            const settingsFile = `${tenantDir}/isp-settings.json`;
            const configFile = `/app/isp-config/${slug}.json`;
            try {
              fs.mkdirSync(tenantDir, { recursive: true });
              fs.mkdirSync('/app/isp-config', { recursive: true });
              if (!fs.existsSync(settingsFile)) fs.writeFileSync(settingsFile, JSON.stringify({ ispName:m.isp_name||slug, domain:m.isp_domain||'', accentColor:'#00C2CB', logoUrl:'', supportEmail:m.isp_email||`support@${m.isp_domain||slug+'.com'}`, stripeKey:'', stripeWebhookSecret:'' }, null, 2));
              if (!fs.existsSync(configFile)) fs.writeFileSync(configFile, JSON.stringify({ slug, name:m.isp_name||slug, domain:m.isp_domain||'', logo_url:'', accent_color:'#00C2CB', support_email:m.isp_email||'', stripe_customer_id:sess.customer, stripe_subscription_id:sess.subscription, provisioned_at:new Date().toISOString() }, null, 2));
              const logPath = '/app/data/provisioning-log.json';
              let log = []; try { log = JSON.parse(fs.readFileSync(logPath,'utf8')); } catch {}
              log.push({ slug, ispName:m.isp_name, domain:m.isp_domain, email:m.isp_email, stripeCustomerId:sess.customer, provisionedAt:new Date().toISOString() });
              fs.writeFileSync(logPath, JSON.stringify(log, null, 2));
            } catch (provErr) { console.error('[4C] Auto-provision failed:', provErr); }
          }
          break;
        }
      }
      res.json({ received: true });
    } catch (err) { console.error('Webhook error:', err); res.status(500).json({ error: String(err) }); }
  });

  // ── ISP signup (new tenant checkout) ─────────────────────────────────────
  router.post('/isp-signup', async (req, res) => {
    const stripe = getStripe();
    if (!stripe) return res.status(400).json({ error: 'Stripe not configured on this node.' });
    const { planId, ispName, contactEmail, slug, domain, city, state, successUrl, cancelUrl, accentColor } = req.body;
    if (!planId || !ispName || !contactEmail || !slug) return res.status(400).json({ error: 'planId, ispName, contactEmail, and slug are required.' });
    const plan = STRIPE_PLANS.find(p => p.id === planId);
    if (!plan) return res.status(400).json({ error: 'Unknown plan' });
    const settings = loadSettings();
    const priceId = settings.stripeKey?.startsWith('sk_test_') ? plan.stripePriceIdTest : plan.stripePriceId;
    try {
      const customer = await stripe.customers.create({ email: contactEmail, name: ispName, metadata: { isp_slug: slug, isp_domain: domain||'', isp_city: city||'', isp_state: state||'' } });
      const base = successUrl || portalUrl('/isp-portal/#/signup/success');
      const session = await stripe.checkout.sessions.create({
        mode: 'subscription', customer: customer.id,
        line_items: [{ price: priceId, quantity: 1 }],
        subscription_data: { trial_period_days: 14, metadata: { isp_slug: slug, isp_name: ispName, isp_domain: domain||'' } },
        success_url: base + (base.includes('?') ? '&' : '?') + 'session_id={CHECKOUT_SESSION_ID}',
        cancel_url: cancelUrl || portalUrl('/isp-portal/#/signup'),
        metadata: { isp_slug: slug, isp_name: ispName, isp_domain: domain||'', isp_email: contactEmail, isp_city: city||'', isp_state: state||'', isp_accent: accentColor||'#00C2CB', provision_type: 'new_isp' },
      });
      res.json({ url: session.url });
    } catch (err) { res.status(500).json({ error: String(err) }); }
  });

  // ── Tenant provisioning ───────────────────────────────────────────────────
  router.post('/provision-tenant', async (req, res) => {
    const { execSync } = require('child_process');
    const { sessionId, slug: directSlug, ispName: directName, domain: directDomain, email: directEmail, accentColor: directAccent } = req.body || {};
    let slug = directSlug, ispName = directName, domain = directDomain, email = directEmail, accentColor = directAccent || '#00C2CB';
    if (sessionId) {
      const stripe = getStripe();
      if (stripe) {
        try {
          const session = await stripe.checkout.sessions.retrieve(sessionId);
          const m = session.metadata || {};
          slug = slug||m.isp_slug; ispName = ispName||m.isp_name; domain = domain||m.isp_domain; email = email||m.isp_email; accentColor = accentColor||m.isp_accent||'#00C2CB';
        } catch {}
      }
    }
    if (!slug) return res.status(400).json({ error: 'slug is required' });
    slug = slug.replace(/[^a-z0-9-]/g, '-').replace(/(^-|-$)/g, '');
    const tenantDataDir = `/app/data/${slug}`, settingsPath = `${tenantDataDir}/isp-settings.json`;
    const configPath = `/app/isp-config/${slug}.json`, containerName = `etheros-isp-${slug}`;
    const steps = [];
    try {
      fs.mkdirSync(tenantDataDir, { recursive: true }); fs.mkdirSync('/app/isp-config', { recursive: true }); steps.push('data_dir');
      if (!fs.existsSync(settingsPath)) { fs.writeFileSync(settingsPath, JSON.stringify({ ispName:ispName||slug, domain:domain||'', accentColor, logoUrl:'', supportEmail:email||`support@${domain||slug+'.com'}`, stripeKey:'', stripeWebhookSecret:'' }, null, 2)); }
      steps.push('settings');
      if (!fs.existsSync(configPath)) { fs.writeFileSync(configPath, JSON.stringify({ slug, name:ispName||slug, domain:domain||'', logo_url:'', accent_color:accentColor, support_email:email||`support@${domain||slug+'.com'}`, provisioned_at:new Date().toISOString() }, null, 2)); }
      steps.push('config');
      const logPath = '/app/data/provisioning-log.json';
      let log = []; try { log = JSON.parse(fs.readFileSync(logPath,'utf8')); } catch {}
      if (!log.some(e => e.slug === slug)) { log.push({ slug, ispName, domain, email, accentColor, provisionedAt: new Date().toISOString() }); fs.writeFileSync(logPath, JSON.stringify(log, null, 2)); }
      steps.push('log');
      let containerStatus = 'skipped';
      try {
        const running = execSync(`docker ps --filter name=^${containerName}$ --format '{{.Status}}'`, { encoding:'utf8' }).trim();
        if (!running) {
          let port = 3020;
          const usedPorts = execSync(`docker ps --format '{{.Ports}}' 2>/dev/null || true`, { encoding:'utf8' });
          while (usedPorts.includes(`127.0.0.1:${port}->`) && port < 3100) port++;
          execSync(['docker run -d', `--name ${containerName}`, '--network etheros-edge_edge-internal', '--restart unless-stopped', `-p 127.0.0.1:${port}:3010`, '-v /opt/etheros-edge/backends/isp-portal:/app:rw', `-e TENANT_SLUG=${slug}`, `-e TENANT_DOMAIN=${domain||'edge.etheros.ai'}`, '-e NODE_ENV=production', `--label etheros.tenant=${slug}`, `--label etheros.domain=${domain||''}`, 'etheros-edge_etheros-isp-portal-backend'].join(' '), { encoding:'utf8' });
          try { const cfg = JSON.parse(fs.readFileSync(configPath,'utf8')); cfg.backend_port = port; fs.writeFileSync(configPath, JSON.stringify(cfg, null, 2)); } catch {}
          containerStatus = `started:${port}`; steps.push(`container:${port}`);
        } else { containerStatus = 'already_running'; steps.push('container:already_running'); }
      } catch (dockerErr) { containerStatus = `error:${dockerErr.message}`; steps.push('container:error'); }
      let nginxStatus = 'skipped';
      if (domain) {
        try {
          const nginxConfDir = '/opt/etheros-edge/nginx/conf.d', templatePath = '/opt/etheros-edge/nginx/tenant-vhost.conf.template', vhostPath = `${nginxConfDir}/${slug}.conf`;
          if (!fs.existsSync(vhostPath) && fs.existsSync(templatePath)) {
            const cfg = JSON.parse(fs.readFileSync(configPath,'utf8')), port = cfg.backend_port||3020;
            const vhost = fs.readFileSync(templatePath,'utf8').replace(/__DOMAIN__/g,domain).replace(/__SLUG__/g,slug).replace(/__ISP_NAME__/g,ispName||slug).replace(/__ACCENT_COLOR__/g,accentColor).replace(/__PORT__/g,String(port));
            fs.mkdirSync(nginxConfDir, { recursive:true }); fs.writeFileSync(vhostPath, vhost);
            execSync('docker exec etheros-nginx nginx -s reload', { encoding:'utf8' });
            nginxStatus = 'reloaded'; steps.push('nginx:reloaded');
          } else { nginxStatus = fs.existsSync(vhostPath) ? 'already_exists' : 'template_not_found'; steps.push(`nginx:${nginxStatus}`); }
        } catch (nginxErr) { nginxStatus = `error:${nginxErr.message}`; steps.push('nginx:error'); }
      }
      res.json({ ok:true, slug, ispName:ispName||slug, domain:domain||'', portalUrl:domain?`https://${domain}/isp-portal/`:`https://edge.etheros.ai/isp-portal/`, dataDir:tenantDataDir, containerStatus, nginxStatus, steps });
    } catch (err) { res.status(500).json({ error: String(err), steps }); }
  });

  // GET /api/billing/tenants
  router.get('/tenants', (req, res) => {
    try {
      const { execSync } = require('child_process');
      const logPath = '/app/data/provisioning-log.json';
      let log = []; try { log = JSON.parse(fs.readFileSync(logPath,'utf8')); } catch {}
      const configDir = '/app/isp-config';
      let configs = [];
      if (fs.existsSync(configDir)) {
        configs = fs.readdirSync(configDir).filter(f => f.endsWith('.json')).map(f => { try { return JSON.parse(fs.readFileSync(`${configDir}/${f}`,'utf8')); } catch { return null; } }).filter(Boolean);
      }
      let dockerStatus = {};
      try {
        const lines = execSync(`docker ps -a --filter label=etheros.tenant --format '{{.Names}}\t{{.Status}}'`, { encoding:'utf8' }).trim().split('\n').filter(Boolean);
        for (const line of lines) { const [name, ...rest] = line.split('\t'); const slug = name.replace('etheros-isp-',''); dockerStatus[slug] = rest.join('\t'); }
      } catch {}
      const enriched = configs.map(c => ({ ...c, container:{ name:`etheros-isp-${c.slug}`, status:dockerStatus[c.slug]||'not_started', healthy:(dockerStatus[c.slug]||'').toLowerCase().startsWith('up') }, portalUrl:c.domain?`https://${c.domain}/isp-portal/`:`https://edge.etheros.ai/isp-portal/` }));
      res.json({ tenants: enriched, provisioningLog: log });
    } catch (err) { res.status(500).json({ error: String(err) }); }
  });

  return router;
};
