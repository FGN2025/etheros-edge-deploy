'use strict';
/**
 * server.js — EtherOS ISP Portal Backend  (Sprint 4S — hardened)
 *
 * Changes from 4R:
 *   - requireAdmin middleware applied to all ISP admin routes
 *   - JSON→SQLite migration forced on startup (not lazy)
 *   - JSON watchdog removed (terminals.js handles offline sweep via SQLite)
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
  const s = loadSettings();
  const key = (s.stripeKey || '').trim();
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

// ── Auth middleware ───────────────────────────────────────────────────────────
const { createAdminRouter, adminSessions } = require('./routes/admin');
const { requireAdmin, rateLimiter }        = require('./routes/middleware');
const auth = requireAdmin(adminSessions, loadSettings);

// ── Route modules ─────────────────────────────────────────────────────────────

// ── Terminals (/api/terminals/**) — admin protected ──────────────────────────
const terminalsRouter = require('./routes/terminals')(DATA_DIR);
app.use('/api/terminals', auth, terminalsRouter);

// ── Subscribers (/api/subscribers/**) ────────────────────────────────────────
// PUBLIC: /auth  /auth/pin/:id  /me  (terminal kiosk)
// ADMIN:  everything else
const subscribersRouter = require('./routes/subscribers')(DATA_DIR, loadSettings, getStripe, portalUrl);
app.post('/api/subscribers/auth',        rateLimiter(60_000, 20), subscribersRouter); // PIN login — public, rate-limited
app.get('/api/subscribers/auth/pin/:id', subscribersRouter);                           // PIN lookup — public
app.get('/api/subscribers/me',           subscribersRouter);                           // self-read — public
app.use('/api/subscribers',              auth, subscribersRouter);                     // all else — admin

// ── Agents (/api/agents/**) ───────────────────────────────────────────────────
// PUBLIC: /browse (terminal kiosk fetches available agents)
// ADMIN:  everything else
const agentsRouter = require('./routes/agents')(DATA_DIR);
app.use('/api/agents/browse', agentsRouter);           // public
app.use('/api/agents',        auth, agentsRouter);     // admin

// ── Marketing (/api/marketing/**) — admin protected ──────────────────────────
const marketingRouter = require('./routes/marketing')(DATA_DIR, loadSettings);
app.use('/api/marketing', auth, marketingRouter);

// ── Acquisition (/api/acquisition/**) ────────────────────────────────────────
// PUBLIC: /pages/:slug/render  /leads (POST — lead capture form submissions)
// ADMIN:  /pages CRUD  /leads GET (lead inbox)
const acquisitionRouter = require('./routes/acquisition')(DATA_DIR, loadSettings);
app.use('/api/acquisition/pages/:slug/render', acquisitionRouter);   // public page render
app.post('/api/acquisition/leads',             acquisitionRouter);   // public lead capture
app.use('/api/acquisition',                    auth, acquisitionRouter); // admin CRUD

// ── Billing (/api/billing/**) ─────────────────────────────────────────────────
// PUBLIC: /webhook (Stripe — verified by signature)  /plans
// ADMIN:  everything else
const billingRouter = require('./routes/billing')(DATA_DIR, loadSettings, getStripe, portalUrl);
app.use('/api/billing/webhook', billingRouter);                  // public — Stripe webhook
app.use('/api/billing/plans',   billingRouter);                  // public — pricing page
app.use('/api/billing',         auth, billingRouter);            // admin

// ── Dashboard (/api/dashboard  /api/server-stats  /api/revenue) — admin ──────
const { createDashboardRouter } = require('./routes/dashboard');
app.use('/api', auth, createDashboardRouter(shared));

// ── Chat (/api/chat/stream) — subscriber token auth (handled inside router) ──
const { createChatRouter } = require('./routes/chat');
app.use('/api', createChatRouter(shared));

// ── Admin router ─────────────────────────────────────────────────────────────
const adminRouter = createAdminRouter(shared);

// PUBLIC — terminal kiosk reads these on boot (must be registered BEFORE auth catch-all)
app.get('/api/tenant',          adminRouter);
app.get('/api/terminal/config', adminRouter);
app.get('/api/isp-config',      adminRouter);

// PUBLIC — login/logout (can't require auth to log in)
app.post('/api/admin/login',  rateLimiter(60_000, 10), adminRouter);
app.post('/api/admin/logout', adminRouter);

// PROTECTED — all remaining /api/* admin routes
app.use('/api', auth, adminRouter);

// ── Health — public, no auth ──────────────────────────────────────────────────
app.get('/health', (req, res) => {
  const s = loadSettings();
  res.json({
    status: 'ok',
    service: 'isp-portal-backend',
    version: '2.0.0-4s',
    tenant: TENANT_SLUG || 'default',
    ispName: s.ispName || null,
    domain: s.domain || getPortalDomain(),
    ts: new Date().toISOString(),
  });
});

// ── Startup: force JSON→SQLite migration ─────────────────────────────────────
(function runMigration() {
  try {
    const { getDb, migrateFromJson } = require('./db');
    const db = getDb(DATA_DIR);
    if (!db) {
      console.log('[migration] better-sqlite3 not available — running in JSON shim mode');
      return;
    }
    const result = migrateFromJson(db, DATA_DIR);
    if (result.skipped) {
      console.log('[migration] already migrated — skipping');
    } else {
      console.log('[migration] JSON→SQLite complete:', JSON.stringify(result));
    }
  } catch (err) {
    console.error('[migration] failed (non-fatal):', err.message);
  }
})();

// ── Start ─────────────────────────────────────────────────────────────────────
const PORT = process.env.PORT || 3010;
app.listen(PORT, () => {
  console.log(`[isp-portal] listening on :${PORT}  tenant=${TENANT_SLUG || 'default'}  version=4S`);
});
