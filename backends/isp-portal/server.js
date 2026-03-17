'use strict';
/**
 * server.js — EtherOS ISP Portal Backend  (Sprint 4R — thin wiring layer)
 *
 * All business logic lives in routes/*.js — this file only:
 *   1. Sets up Express + middleware
 *   2. Defines shared helpers (data dir, settings, Stripe, helpers)
 *   3. Imports + mounts each route module
 *   4. Starts the server
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

function portalUrl(p = '') {
  return `https://${getPortalDomain()}${p}`;
}

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
  const s = loadSettings();
  const key = (s.stripeKey || '').trim();
  if (!key) return null;
  try {
    const Stripe = require('stripe');
    return new Stripe(key, { apiVersion: '2024-12-18.acacia' });
  } catch { return null; }
}

// ── Subscriber token helpers (shared with chat + subscribers routes) ───────────
function makeToken(subscriberId) {
  const payload = `${subscriberId}.${Date.now()}`;
  return Buffer.from(payload).toString('base64url');
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
  DATA_DIR,
  TENANT_SLUG,
  EDGE_API,
  loadSettings,
  saveSettings,
  getStripe,
  portalUrl,
  getPortalDomain,
  makeToken,
  parseToken,
};

// ── Route modules ─────────────────────────────────────────────────────────────

// Terminals — terminal CRUD, register, heartbeat
const terminalsRouter = require('./routes/terminals')(DATA_DIR);
app.use('/api', terminalsRouter);

// Subscribers — subscriber CRUD, PIN auth, agent slots, billing, Blacknut, chat history
const subscribersRouter = require('./routes/subscribers')(DATA_DIR, loadSettings, getStripe, portalUrl);
app.use('/api', subscribersRouter);

// Agents — agent catalog, seed defaults, toggle, browse
const agentsRouter = require('./routes/agents')(DATA_DIR);
app.use('/api', agentsRouter);

// Marketing — campaigns, marketing pages, marketer users
const marketingRouter = require('./routes/marketing')(DATA_DIR, loadSettings);
app.use('/api', marketingRouter);

// Acquisition — landing pages, lead capture, lead inbox, Resend notify
const acquisitionRouter = require('./routes/acquisition')(DATA_DIR, loadSettings);
app.use('/api', acquisitionRouter);

// Billing — ISP Stripe billing, webhook, provision-tenant, tenants list
const billingRouter = require('./routes/billing')(DATA_DIR, loadSettings, getStripe, portalUrl);
app.use('/api', billingRouter);

// Dashboard — KPIs, server-stats, revenue
const { createDashboardRouter } = require('./routes/dashboard');
const dashboardRouter = createDashboardRouter(shared);
app.use('/api', dashboardRouter);

// Chat — SSE proxy to Ollama for subscriber terminal inline chat
const { createChatRouter } = require('./routes/chat');
const chatRouter = createChatRouter(shared);
app.use('/api', chatRouter);

// Admin — settings, auth, edge-status, edge-chat, isp-config, terminal/config, tenant
const { createAdminRouter } = require('./routes/admin');
const adminRouter = createAdminRouter(shared);
app.use('/api', adminRouter);

// Health — mounted at root (no /api prefix)
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

// ── Terminal offline watchdog ─────────────────────────────────────────────────
// Mark terminals offline after 3 min without a heartbeat
const TERMINALS_FILE = `${DATA_DIR}/terminals.json`;
function loadJSON(file, fallback = []) {
  try { return JSON.parse(fs.readFileSync(file, 'utf8')); }
  catch { return fallback; }
}
function saveJSON(file, data) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, JSON.stringify(data, null, 2));
}

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

// ── Start ─────────────────────────────────────────────────────────────────────
const PORT = process.env.PORT || 3010;
app.listen(PORT, () => {
  console.log(`[isp-portal] listening on :${PORT}  tenant=${TENANT_SLUG || 'default'}`);
});
