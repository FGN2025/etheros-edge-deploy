'use strict';
/**
 * db.js — SQLite persistence layer for EtherOS ISP Portal
 * Sprint 4R: replaces per-entity flat JSON files with a single SQLite database.
 *
 * One database per tenant: ${DATA_DIR}/etheros.db
 * All helpers are synchronous (better-sqlite3) for drop-in JSON replacement.
 * Migration from JSON runs automatically on first boot if .db doesn't exist yet.
 */

const fs   = require('fs');
const path = require('path');

let Database;
try {
  Database = require('better-sqlite3');
} catch {
  // better-sqlite3 not installed yet — fall back to JSON shim so deploy doesn't break
  Database = null;
}

// ── Schema DDL ────────────────────────────────────────────────────────────────

const SCHEMA = `
PRAGMA journal_mode=WAL;
PRAGMA foreign_keys=ON;

CREATE TABLE IF NOT EXISTS settings (
  key   TEXT PRIMARY KEY,
  value TEXT
);

CREATE TABLE IF NOT EXISTS terminals (
  id                TEXT PRIMARY KEY,
  hostname          TEXT NOT NULL,
  ip                TEXT NOT NULL,
  tier              INTEGER DEFAULT 1,
  status            TEXT DEFAULT 'provisioning',
  os_version        TEXT DEFAULT 'EtherOS 1.0',
  model_version     TEXT DEFAULT '',
  model_loaded      TEXT DEFAULT '',
  cpu_percent       REAL DEFAULT 0,
  ram_percent       REAL DEFAULT 0,
  disk_percent      REAL DEFAULT 0,
  last_inference_ms INTEGER DEFAULT 0,
  uptime            TEXT DEFAULT '0m',
  last_seen         TEXT,
  registered_at     TEXT DEFAULT (datetime('now'))
);

CREATE TABLE IF NOT EXISTS subscribers (
  id                          TEXT PRIMARY KEY,
  name                        TEXT NOT NULL,
  email                       TEXT UNIQUE NOT NULL,
  plan                        TEXT NOT NULL DEFAULT 'personal',
  status                      TEXT DEFAULT 'active',
  agents_active               INTEGER DEFAULT 0,
  monthly_spend               REAL DEFAULT 0,
  joined_at                   TEXT DEFAULT (datetime('now')),
  isp                         TEXT,
  -- Stripe billing fields
  stripe_customer_id          TEXT,
  stripe_subscription_id      TEXT,
  stripe_checkout_session_id  TEXT,
  billing_status              TEXT DEFAULT 'none',
  billing_invited_at          TEXT,
  current_period_end          TEXT,
  cancel_at_period_end        INTEGER DEFAULT 0,
  -- Agent slots (JSON array of agent IDs)
  active_agent_ids            TEXT DEFAULT '[]'
);

CREATE TABLE IF NOT EXISTS agents (
  id               TEXT PRIMARY KEY,
  name             TEXT NOT NULL,
  slug             TEXT,
  description      TEXT,
  category         TEXT DEFAULT 'Productivity',
  creator_role     TEXT DEFAULT 'isp',
  status           TEXT DEFAULT 'live',
  pricing_type     TEXT DEFAULT 'free',
  price_monthly    REAL DEFAULT 0,
  is_enabled       INTEGER DEFAULT 1,
  model_id         TEXT DEFAULT 'llama3.1:8b',
  system_prompt    TEXT DEFAULT '',
  notebook_sources TEXT DEFAULT '[]',
  activation_count INTEGER DEFAULT 0
);

CREATE TABLE IF NOT EXISTS chat_messages (
  id            INTEGER PRIMARY KEY AUTOINCREMENT,
  subscriber_id TEXT NOT NULL,
  agent_id      TEXT NOT NULL,
  role          TEXT NOT NULL,
  content       TEXT NOT NULL,
  timestamp     TEXT DEFAULT (datetime('now')),
  FOREIGN KEY (subscriber_id) REFERENCES subscribers(id) ON DELETE CASCADE
);
CREATE INDEX IF NOT EXISTS idx_chat_sub_agent ON chat_messages(subscriber_id, agent_id);

CREATE TABLE IF NOT EXISTS campaigns (
  id              TEXT PRIMARY KEY,
  name            TEXT NOT NULL,
  type            TEXT DEFAULT 'social',
  status          TEXT DEFAULT 'draft',
  agent_id        TEXT,
  agent_name      TEXT,
  agent_category  TEXT,
  agent_image_url TEXT,
  headline        TEXT DEFAULT '',
  body            TEXT DEFAULT '',
  cta_text        TEXT DEFAULT 'Try it now',
  cta_url         TEXT DEFAULT '',
  hero_image_url  TEXT,
  target_plans    TEXT DEFAULT '["personal","professional","charter"]',
  scheduled_at    TEXT,
  created_by      TEXT DEFAULT 'admin',
  created_at      TEXT DEFAULT (datetime('now')),
  updated_at      TEXT DEFAULT (datetime('now'))
);

CREATE TABLE IF NOT EXISTS marketing_pages (
  id            TEXT PRIMARY KEY,
  slug          TEXT UNIQUE NOT NULL,
  title         TEXT NOT NULL,
  hero_image_url TEXT,
  headline      TEXT,
  body_html     TEXT DEFAULT '',
  features      TEXT DEFAULT '[]',
  cta_text      TEXT DEFAULT 'Try it now',
  cta_url       TEXT DEFAULT '/#/terminal',
  agent_id      TEXT,
  agent_name    TEXT,
  published     INTEGER DEFAULT 0,
  created_at    TEXT DEFAULT (datetime('now')),
  updated_at    TEXT DEFAULT (datetime('now'))
);

CREATE TABLE IF NOT EXISTS marketing_users (
  id         TEXT PRIMARY KEY,
  name       TEXT NOT NULL,
  email      TEXT NOT NULL,
  role       TEXT DEFAULT 'marketer',
  token      TEXT UNIQUE NOT NULL,
  active     INTEGER DEFAULT 1,
  created_at TEXT DEFAULT (datetime('now'))
);

CREATE TABLE IF NOT EXISTS acquisition_pages (
  id          TEXT PRIMARY KEY,
  title       TEXT NOT NULL,
  slug        TEXT UNIQUE NOT NULL,
  template    TEXT DEFAULT 'isp-recruit',
  page_type   TEXT DEFAULT 'isp',
  content     TEXT DEFAULT '{}',
  published   INTEGER DEFAULT 0,
  views       INTEGER DEFAULT 0,
  leads       INTEGER DEFAULT 0,
  created_at  TEXT DEFAULT (datetime('now')),
  updated_at  TEXT DEFAULT (datetime('now'))
);

CREATE TABLE IF NOT EXISTS acquisition_leads (
  id          TEXT PRIMARY KEY,
  name        TEXT NOT NULL,
  email       TEXT NOT NULL,
  phone       TEXT DEFAULT '',
  company     TEXT DEFAULT '',
  message     TEXT DEFAULT '',
  page_slug   TEXT NOT NULL,
  lead_type   TEXT DEFAULT 'general',
  status      TEXT DEFAULT 'new',
  created_at  TEXT DEFAULT (datetime('now'))
);
CREATE INDEX IF NOT EXISTS idx_leads_page ON acquisition_leads(page_slug);
CREATE INDEX IF NOT EXISTS idx_leads_status ON acquisition_leads(status);

CREATE TABLE IF NOT EXISTS revenue_history (
  id               INTEGER PRIMARY KEY AUTOINCREMENT,
  month            TEXT UNIQUE NOT NULL,
  total_revenue    REAL DEFAULT 0,
  isp_share        REAL DEFAULT 0,
  agent_revenue    REAL DEFAULT 0,
  subscriber_count INTEGER DEFAULT 0,
  seeded           INTEGER DEFAULT 0
);

CREATE TABLE IF NOT EXISTS billing_state (
  id                    INTEGER PRIMARY KEY CHECK (id = 1),
  customer_id           TEXT,
  subscription_id       TEXT,
  plan_id               TEXT,
  status                TEXT DEFAULT 'none',
  current_period_end    TEXT,
  cancel_at_period_end  INTEGER DEFAULT 0,
  trial_end             TEXT,
  payment_method_last4  TEXT,
  payment_method_brand  TEXT
);
INSERT OR IGNORE INTO billing_state (id) VALUES (1);
`;

// ── DB factory ────────────────────────────────────────────────────────────────

const _instances = new Map();

function getDb(dataDir) {
  if (!Database) return null; // shim mode
  if (_instances.has(dataDir)) return _instances.get(dataDir);

  fs.mkdirSync(dataDir, { recursive: true });
  const dbPath = path.join(dataDir, 'etheros.db');
  const db = new Database(dbPath);
  db.exec(SCHEMA);
  _instances.set(dataDir, db);
  return db;
}

// ── JSON → SQLite one-time migration ─────────────────────────────────────────

function migrateFromJson(db, dataDir) {
  const migFlagPath = path.join(dataDir, '.migrated');
  if (fs.existsSync(migFlagPath)) return { skipped: true };

  const results = {};

  function readJson(file, fallback = []) {
    try { return JSON.parse(fs.readFileSync(path.join(dataDir, file), 'utf8')); }
    catch { return fallback; }
  }

  // Terminals
  const terminals = readJson('terminals.json');
  const insertTerminal = db.prepare(`
    INSERT OR IGNORE INTO terminals
      (id,hostname,ip,tier,status,os_version,model_version,model_loaded,
       cpu_percent,ram_percent,disk_percent,last_inference_ms,uptime,last_seen,registered_at)
    VALUES (@id,@hostname,@ip,@tier,@status,@os_version,@model_version,@model_loaded,
            @cpu_percent,@ram_percent,@disk_percent,@last_inference_ms,@uptime,@last_seen,@registered_at)
  `);
  const txT = db.transaction((rows) => rows.forEach(t => insertTerminal.run({
    id: t.id, hostname: t.hostname, ip: t.ip, tier: t.tier||1, status: t.status||'provisioning',
    os_version: t.osVersion||'EtherOS 1.0', model_version: t.modelVersion||'',
    model_loaded: t.modelLoaded||'', cpu_percent: t.cpuPercent||0,
    ram_percent: t.ramPercent||0, disk_percent: t.diskPercent||0,
    last_inference_ms: t.lastInferenceTime||0, uptime: t.uptime||'0m',
    last_seen: t.lastSeen||null, registered_at: t.registeredAt||new Date().toISOString(),
  })));
  txT(terminals);
  results.terminals = terminals.length;

  // Subscribers
  const subscribers = readJson('subscribers.json');
  const insertSub = db.prepare(`
    INSERT OR IGNORE INTO subscribers
      (id,name,email,plan,status,agents_active,monthly_spend,joined_at,isp,
       stripe_customer_id,stripe_subscription_id,stripe_checkout_session_id,
       billing_status,billing_invited_at,current_period_end,cancel_at_period_end,active_agent_ids)
    VALUES (@id,@name,@email,@plan,@status,@agents_active,@monthly_spend,@joined_at,@isp,
            @stripe_customer_id,@stripe_subscription_id,@stripe_checkout_session_id,
            @billing_status,@billing_invited_at,@current_period_end,@cancel_at_period_end,@active_agent_ids)
  `);
  const txS = db.transaction((rows) => rows.forEach(s => insertSub.run({
    id: s.id, name: s.name, email: s.email, plan: s.plan||'personal',
    status: s.status||'active', agents_active: s.agentsActive||0,
    monthly_spend: s.monthlySpend||0, joined_at: s.joinedAt||new Date().toISOString(),
    isp: s.isp||null, stripe_customer_id: s.stripeCustomerId||null,
    stripe_subscription_id: s.stripeSubscriptionId||null,
    stripe_checkout_session_id: s.stripeCheckoutSessionId||null,
    billing_status: s.billingStatus||'none',
    billing_invited_at: s.billingInvitedAt||null,
    current_period_end: s.currentPeriodEnd||null,
    cancel_at_period_end: s.cancelAtPeriodEnd ? 1 : 0,
    active_agent_ids: JSON.stringify(s.activeAgentIds||s.agents||[]),
  })));
  txS(subscribers);
  results.subscribers = subscribers.length;

  // Agents
  let agents = [];
  try { agents = JSON.parse(fs.readFileSync(path.join(dataDir, 'agents.json'), 'utf8')); }
  catch { /* will seed defaults later */ }
  if (agents.length > 0) {
    const insertAgent = db.prepare(`
      INSERT OR IGNORE INTO agents
        (id,name,slug,description,category,creator_role,status,pricing_type,
         price_monthly,is_enabled,model_id,system_prompt,notebook_sources,activation_count)
      VALUES (@id,@name,@slug,@description,@category,@creator_role,@status,@pricing_type,
              @price_monthly,@is_enabled,@model_id,@system_prompt,@notebook_sources,@activation_count)
    `);
    const txA = db.transaction((rows) => rows.forEach(a => insertAgent.run({
      id: a.id, name: a.name, slug: a.slug||a.name.toLowerCase().replace(/[^a-z0-9]+/g,'-'),
      description: a.description||'', category: a.category||'Productivity',
      creator_role: a.creatorRole||'isp', status: a.status||'live',
      pricing_type: a.pricingType||'free', price_monthly: a.priceMonthly||0,
      is_enabled: a.isEnabled ? 1 : 0, model_id: a.modelId||'llama3.1:8b',
      system_prompt: a.systemPrompt||'',
      notebook_sources: JSON.stringify(a.notebookSources||[]),
      activation_count: a.activationCount||0,
    })));
    txA(agents);
    results.agents = agents.length;
  }

  // Campaigns
  const campaigns = readJson('marketing-campaigns.json');
  if (campaigns.length > 0) {
    const ins = db.prepare(`
      INSERT OR IGNORE INTO campaigns
        (id,name,type,status,agent_id,agent_name,agent_category,agent_image_url,
         headline,body,cta_text,cta_url,hero_image_url,target_plans,scheduled_at,
         created_by,created_at,updated_at)
      VALUES (@id,@name,@type,@status,@agent_id,@agent_name,@agent_category,@agent_image_url,
              @headline,@body,@cta_text,@cta_url,@hero_image_url,@target_plans,@scheduled_at,
              @created_by,@created_at,@updated_at)
    `);
    db.transaction((rows) => rows.forEach(c => ins.run({
      id: c.id, name: c.name, type: c.type||'social', status: c.status||'draft',
      agent_id: c.agentId||null, agent_name: c.agentName||null,
      agent_category: c.agentCategory||null, agent_image_url: c.agentImageUrl||null,
      headline: c.headline||'', body: c.body||'',
      cta_text: c.ctaText||'Try it now', cta_url: c.ctaUrl||'',
      hero_image_url: c.heroImageUrl||null,
      target_plans: JSON.stringify(c.targetPlans||['personal','professional','charter']),
      scheduled_at: c.scheduledAt||null, created_by: c.createdBy||'admin',
      created_at: c.createdAt||new Date().toISOString(),
      updated_at: c.updatedAt||new Date().toISOString(),
    })))(campaigns);
    results.campaigns = campaigns.length;
  }

  // Marketing pages
  const mktgPages = readJson('marketing-pages.json');
  if (mktgPages.length > 0) {
    const ins = db.prepare(`
      INSERT OR IGNORE INTO marketing_pages
        (id,slug,title,hero_image_url,headline,body_html,features,cta_text,cta_url,
         agent_id,agent_name,published,created_at,updated_at)
      VALUES (@id,@slug,@title,@hero_image_url,@headline,@body_html,@features,@cta_text,@cta_url,
              @agent_id,@agent_name,@published,@created_at,@updated_at)
    `);
    db.transaction((rows) => rows.forEach(p => ins.run({
      id: p.id, slug: p.slug, title: p.title, hero_image_url: p.heroImageUrl||null,
      headline: p.headline||p.title, body_html: p.bodyHtml||'',
      features: JSON.stringify(p.features||[]), cta_text: p.ctaText||'Try it now',
      cta_url: p.ctaUrl||'/#/terminal', agent_id: p.agentId||null,
      agent_name: p.agentName||null, published: p.published ? 1 : 0,
      created_at: p.createdAt||new Date().toISOString(),
      updated_at: p.updatedAt||new Date().toISOString(),
    })))(mktgPages);
    results.marketingPages = mktgPages.length;
  }

  // Marketing users
  const mktgUsers = readJson('marketing-users.json', { marketerUsers: [] });
  const users = mktgUsers.marketerUsers || [];
  if (users.length > 0) {
    const ins = db.prepare(`
      INSERT OR IGNORE INTO marketing_users (id,name,email,role,token,active,created_at)
      VALUES (@id,@name,@email,@role,@token,@active,@created_at)
    `);
    db.transaction((rows) => rows.forEach(u => ins.run({
      id: u.id, name: u.name, email: u.email, role: u.role||'marketer',
      token: u.token, active: u.active !== false ? 1 : 0,
      created_at: u.createdAt||new Date().toISOString(),
    })))(users);
    results.marketingUsers = users.length;
  }

  // Acquisition pages
  const acqPages = readJson('acquisition-pages.json');
  if (acqPages.length > 0) {
    const ins = db.prepare(`
      INSERT OR IGNORE INTO acquisition_pages
        (id,title,slug,template,page_type,content,published,views,leads,created_at,updated_at)
      VALUES (@id,@title,@slug,@template,@page_type,@content,@published,@views,@leads,@created_at,@updated_at)
    `);
    db.transaction((rows) => rows.forEach(p => ins.run({
      id: p.id, title: p.title, slug: p.slug, template: p.template||'isp-recruit',
      page_type: p.pageType||'isp', content: JSON.stringify(p.content||{}),
      published: p.published ? 1 : 0, views: p.views||0, leads: p.leads||0,
      created_at: p.createdAt||new Date().toISOString(),
      updated_at: p.updatedAt||new Date().toISOString(),
    })))(acqPages);
    results.acquisitionPages = acqPages.length;
  }

  // Acquisition leads
  const acqLeads = readJson('acquisition-leads.json');
  if (acqLeads.length > 0) {
    const ins = db.prepare(`
      INSERT OR IGNORE INTO acquisition_leads
        (id,name,email,phone,company,message,page_slug,lead_type,status,created_at)
      VALUES (@id,@name,@email,@phone,@company,@message,@page_slug,@lead_type,@status,@created_at)
    `);
    db.transaction((rows) => rows.forEach(l => ins.run({
      id: l.id, name: l.name, email: l.email, phone: l.phone||'',
      company: l.company||'', message: l.message||'',
      page_slug: l.pageSlug, lead_type: l.leadType||'general',
      status: l.status||'new', created_at: l.createdAt||new Date().toISOString(),
    })))(acqLeads);
    results.acquisitionLeads = acqLeads.length;
  }

  // Revenue history
  const revenue = readJson('revenue-history.json');
  if (revenue.length > 0) {
    const ins = db.prepare(`
      INSERT OR IGNORE INTO revenue_history
        (month,total_revenue,isp_share,agent_revenue,subscriber_count,seeded)
      VALUES (@month,@total_revenue,@isp_share,@agent_revenue,@subscriber_count,@seeded)
    `);
    db.transaction((rows) => rows.forEach(r => ins.run({
      month: r.month, total_revenue: r.totalRevenue||0, isp_share: r.ispShare||0,
      agent_revenue: r.agentRevenue||0, subscriber_count: r.subscriberCount||0,
      seeded: r.seeded ? 1 : 0,
    })))(revenue);
    results.revenue = revenue.length;
  }

  // Billing state
  const billingRaw = readJson('billing-state.json', {});
  if (billingRaw.customerId || billingRaw.subscriptionId) {
    db.prepare(`
      UPDATE billing_state SET
        customer_id=@customer_id, subscription_id=@subscription_id,
        plan_id=@plan_id, status=@status, current_period_end=@current_period_end,
        cancel_at_period_end=@cancel_at_period_end, trial_end=@trial_end,
        payment_method_last4=@payment_method_last4, payment_method_brand=@payment_method_brand
      WHERE id=1
    `).run({
      customer_id: billingRaw.customerId||null,
      subscription_id: billingRaw.subscriptionId||null,
      plan_id: billingRaw.planId||null, status: billingRaw.status||'none',
      current_period_end: billingRaw.currentPeriodEnd||null,
      cancel_at_period_end: billingRaw.cancelAtPeriodEnd ? 1 : 0,
      trial_end: billingRaw.trialEnd||null,
      payment_method_last4: billingRaw.paymentMethodLast4||null,
      payment_method_brand: billingRaw.paymentMethodBrand||null,
    });
  }

  // Chat history (directory scan)
  const chatBaseDir = path.join(dataDir, 'chats');
  let chatMsgCount = 0;
  if (fs.existsSync(chatBaseDir)) {
    const insertMsg = db.prepare(`
      INSERT OR IGNORE INTO chat_messages (subscriber_id,agent_id,role,content,timestamp)
      VALUES (@subscriber_id,@agent_id,@role,@content,@timestamp)
    `);
    const subDirs = fs.readdirSync(chatBaseDir);
    for (const subId of subDirs) {
      const subDir = path.join(chatBaseDir, subId);
      if (!fs.statSync(subDir).isDirectory()) continue;
      const files = fs.readdirSync(subDir).filter(f => f.endsWith('.json'));
      for (const file of files) {
        const agentId = file.replace('.json', '');
        try {
          const msgs = JSON.parse(fs.readFileSync(path.join(subDir, file), 'utf8'));
          db.transaction((rows) => rows.forEach(m => insertMsg.run({
            subscriber_id: subId, agent_id: agentId,
            role: m.role, content: m.content, timestamp: m.timestamp||new Date().toISOString(),
          })))(msgs);
          chatMsgCount += msgs.length;
        } catch {}
      }
    }
  }
  results.chatMessages = chatMsgCount;

  // Mark migration complete
  fs.writeFileSync(migFlagPath, JSON.stringify({ migratedAt: new Date().toISOString(), results }));
  console.log('[4R] JSON→SQLite migration complete:', results);
  return results;
}

// ── Row serializers (snake_case DB → camelCase API) ───────────────────────────

function terminalFromRow(r) {
  if (!r) return null;
  return {
    id: r.id, hostname: r.hostname, ip: r.ip, tier: r.tier, status: r.status,
    osVersion: r.os_version, modelVersion: r.model_version, modelLoaded: r.model_loaded,
    cpuPercent: r.cpu_percent, ramPercent: r.ram_percent, diskPercent: r.disk_percent,
    lastInferenceTime: r.last_inference_ms, uptime: r.uptime,
    lastSeen: r.last_seen, registeredAt: r.registered_at,
  };
}

function subscriberFromRow(r) {
  if (!r) return null;
  return {
    id: r.id, name: r.name, email: r.email, plan: r.plan, status: r.status,
    agentsActive: r.agents_active, monthlySpend: r.monthly_spend,
    joinedAt: r.joined_at, isp: r.isp,
    stripeCustomerId: r.stripe_customer_id,
    stripeSubscriptionId: r.stripe_subscription_id,
    stripeCheckoutSessionId: r.stripe_checkout_session_id,
    billingStatus: r.billing_status,
    billingInvitedAt: r.billing_invited_at,
    currentPeriodEnd: r.current_period_end,
    cancelAtPeriodEnd: !!r.cancel_at_period_end,
    activeAgentIds: JSON.parse(r.active_agent_ids || '[]'),
  };
}

function agentFromRow(r) {
  if (!r) return null;
  return {
    id: r.id, name: r.name, slug: r.slug, description: r.description,
    category: r.category, creatorRole: r.creator_role, status: r.status,
    pricingType: r.pricing_type, priceMonthly: r.price_monthly,
    isEnabled: !!r.is_enabled, modelId: r.model_id, systemPrompt: r.system_prompt,
    notebookSources: JSON.parse(r.notebook_sources || '[]'),
    activationCount: r.activation_count,
  };
}

function campaignFromRow(r) {
  if (!r) return null;
  return {
    id: r.id, name: r.name, type: r.type, status: r.status,
    agentId: r.agent_id, agentName: r.agent_name,
    agentCategory: r.agent_category, agentImageUrl: r.agent_image_url,
    headline: r.headline, body: r.body, ctaText: r.cta_text, ctaUrl: r.cta_url,
    heroImageUrl: r.hero_image_url,
    targetPlans: JSON.parse(r.target_plans || '[]'),
    scheduledAt: r.scheduled_at, createdBy: r.created_by,
    createdAt: r.created_at, updatedAt: r.updated_at,
  };
}

function mktgPageFromRow(r) {
  if (!r) return null;
  return {
    id: r.id, slug: r.slug, title: r.title, heroImageUrl: r.hero_image_url,
    headline: r.headline, bodyHtml: r.body_html,
    features: JSON.parse(r.features || '[]'),
    ctaText: r.cta_text, ctaUrl: r.cta_url,
    agentId: r.agent_id, agentName: r.agent_name,
    published: !!r.published,
    createdAt: r.created_at, updatedAt: r.updated_at,
  };
}

function acqPageFromRow(r) {
  if (!r) return null;
  return {
    id: r.id, title: r.title, slug: r.slug, template: r.template,
    pageType: r.page_type, content: JSON.parse(r.content || '{}'),
    published: !!r.published, views: r.views, leads: r.leads,
    createdAt: r.created_at, updatedAt: r.updated_at,
  };
}

function acqLeadFromRow(r) {
  if (!r) return null;
  return {
    id: r.id, name: r.name, email: r.email, phone: r.phone,
    company: r.company, message: r.message, pageSlug: r.page_slug,
    leadType: r.lead_type, status: r.status, createdAt: r.created_at,
  };
}

function revenueFromRow(r) {
  if (!r) return null;
  return {
    month: r.month, totalRevenue: r.total_revenue, ispShare: r.isp_share,
    agentRevenue: r.agent_revenue, subscriberCount: r.subscriber_count,
    seeded: !!r.seeded,
  };
}

module.exports = {
  getDb,
  migrateFromJson,
  terminalFromRow,
  subscriberFromRow,
  agentFromRow,
  campaignFromRow,
  mktgPageFromRow,
  acqPageFromRow,
  acqLeadFromRow,
  revenueFromRow,
};
