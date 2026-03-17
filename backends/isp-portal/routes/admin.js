'use strict';
/**
 * routes/admin.js — Sprint 4R
 * Settings CRUD, admin auth, edge-status, edge-chat, isp-config,
 * terminal/config, /health, /api/tenant, /api/services/blacknut/status
 */

const express = require('express');
const { randomBytes } = require('crypto');

// Admin sessions: token → expiry timestamp (in-memory, intentional)
const adminSessions = new Map();
const SESSION_TTL_MS = 8 * 60 * 60 * 1000; // 8 hours

function generateAdminToken() {
  return randomBytes(32).toString('hex');
}

/**
 * @param {object} helpers  { DATA_DIR, loadSettings, saveSettings, getStripe, portalUrl, EDGE_API }
 */
function createAdminRouter(helpers) {
  const { loadSettings, saveSettings, getStripe, portalUrl, EDGE_API } = helpers;
  const router = express.Router();

  // ── GET /api/settings ─────────────────────────────────────────────────────
  router.get('/settings', (req, res) => {
    const s = loadSettings();
    // Mask stripe key before sending to client
    if (s.stripeKey) s.stripeKey = s.stripeKey.substring(0, 8) + '••••••••';
    res.json(s);
  });

  // ── POST /api/settings ────────────────────────────────────────────────────
  router.post('/settings', (req, res) => {
    const existing = loadSettings();
    const update = { ...existing, ...req.body };
    // Keep original key if client echoed back the masked version
    if ((update.stripeKey || '').includes('••••••••')) {
      update.stripeKey = existing.stripeKey;
    }
    saveSettings(update);
    res.json({ ok: true });
  });

  // ── PATCH /api/settings ───────────────────────────────────────────────────
  router.patch('/settings', (req, res) => {
    const existing = loadSettings();
    const update = { ...existing, ...req.body };
    if ((update.stripeKey || '').includes('••••')) {
      update.stripeKey = existing.stripeKey;
    }
    saveSettings(update);
    res.json({ ok: true });
  });

  // ── GET /api/settings/stripe-key-test ────────────────────────────────────
  router.get('/settings/stripe-key-test', async (req, res) => {
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

  // ── POST /api/admin/login ─────────────────────────────────────────────────
  router.post('/admin/login', (req, res) => {
    const { password } = req.body || {};
    const s = loadSettings();
    const expectedPassword = (s.adminPassword || '').trim() || 'admin';
    if (!password || password !== expectedPassword) {
      return res.status(401).json({ error: 'Invalid password' });
    }
    const token = generateAdminToken();
    adminSessions.set(token, Date.now() + SESSION_TTL_MS);
    res.json({ token, expiresIn: SESSION_TTL_MS });
  });

  // ── POST /api/admin/logout ────────────────────────────────────────────────
  router.post('/admin/logout', (req, res) => {
    const token = (req.headers['x-admin-token'] || req.body?.token || '').trim();
    if (token) adminSessions.delete(token);
    res.json({ ok: true });
  });

  // ── GET /api/admin/verify ─────────────────────────────────────────────────
  router.get('/admin/verify', (req, res) => {
    const token = (req.headers['x-admin-token'] || '').trim();
    const s = loadSettings();
    // Legacy: settings.adminToken fallback
    if (s.adminToken && token === s.adminToken) {
      return res.json({ valid: true });
    }
    const expiry = adminSessions.get(token);
    if (expiry && Date.now() < expiry) {
      // Refresh TTL on activity
      adminSessions.set(token, Date.now() + SESSION_TTL_MS);
      return res.json({ valid: true });
    }
    res.status(401).json({ valid: false });
  });

  // ── GET /api/edge-status ──────────────────────────────────────────────────
  router.get('/edge-status', async (req, res) => {
    try {
      const tagsRes = await fetch('http://ollama:11434/api/tags', {
        signal: AbortSignal.timeout(5000),
      }).catch(() => null);
      const health = tagsRes?.ok ? { status: 'ok' } : null;
      const tagsData = tagsRes?.ok ? await tagsRes.json().catch(() => null) : null;
      const models = (tagsData?.models || []).map(m => m.name || m.id).filter(Boolean);
      res.json({
        edgeOnline: !!health, health, models,
        ollamaOnline: models.length > 0,
        checkedAt: new Date().toISOString(),
        edgeUrl: portalUrl(''),
      });
    } catch (err) {
      res.json({
        edgeOnline: false, models: [], ollamaOnline: false,
        error: String(err), checkedAt: new Date().toISOString(),
      });
    }
  });

  // ── POST /api/edge-chat ───────────────────────────────────────────────────
  router.post('/edge-chat', async (req, res) => {
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

  // ── GET /api/isp-config ───────────────────────────────────────────────────
  router.get('/isp-config', (req, res) => {
    const fs = require('fs');
    const path = require('path');
    const configDir = '/opt/etheros-edge/isp-config';
    try {
      const files = fs.readdirSync(configDir).filter(f => f.endsWith('.json'));
      const configs = files.map(f => {
        try { return JSON.parse(fs.readFileSync(path.join(configDir, f), 'utf8')); }
        catch { return null; }
      }).filter(Boolean);
      res.json(configs);
    } catch {
      const s = loadSettings();
      const domain = helpers.getPortalDomain ? helpers.getPortalDomain() : 'edge.etheros.ai';
      const tenantSlug = helpers.TENANT_SLUG || null;
      res.json([{
        slug: tenantSlug || 'etheros-default',
        name: s.ispName || 'EtherOS AI',
        domain: s.domain || domain,
        accent_color: s.accentColor || '#00C2CB',
      }]);
    }
  });

  // ── GET /api/terminal/config ──────────────────────────────────────────────
  router.get('/terminal/config', (req, res) => {
    const s = loadSettings();
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

  // ── GET /api/services/blacknut/status ─────────────────────────────────────
  router.get('/services/blacknut/status', async (req, res) => {
    const s = loadSettings();
    if (!s.blacknutEnabled) {
      return res.json({ enabled: false, status: 'disabled' });
    }
    const apiKey = (s.blacknutApiKey || '').trim();
    if (!apiKey) {
      return res.json({ enabled: true, status: 'no_key', error: 'No Blacknut API key configured' });
    }
    try {
      const r = await fetch('https://api.blacknut.com/v1/status', {
        headers: { Authorization: `Bearer ${apiKey}` },
        signal: AbortSignal.timeout(8000),
      }).catch(() => null);
      if (!r) return res.json({ enabled: true, status: 'unreachable' });
      const data = await r.json().catch(() => ({}));
      res.json({ enabled: true, status: r.ok ? 'ok' : 'error', httpStatus: r.status, ...data });
    } catch (err) {
      res.json({ enabled: true, status: 'error', error: String(err) });
    }
  });

  // ── GET /api/tenant ───────────────────────────────────────────────────────
  router.get('/tenant', (req, res) => {
    const s = loadSettings();
    const name = s.ispName || 'EtherOS';
    const initials = name.split(' ').map(w => w[0]).join('').slice(0, 2).toUpperCase();
    const domain = helpers.getPortalDomain ? helpers.getPortalDomain() : 'edge.etheros.ai';
    res.json({
      slug:        helpers.TENANT_SLUG || 'default',
      name,
      initials,
      domain:      s.domain      || domain,
      accentColor: s.accentColor || '#00C2CB',
      logoUrl:     s.logoUrl     || null,
    });
  });

  // ── GET /health ───────────────────────────────────────────────────────────
  // NOTE: mounted at /health (no /api prefix) — server.js mounts this separately
  router.get('/health', (req, res) => {
    const s = loadSettings();
    const domain = helpers.getPortalDomain ? helpers.getPortalDomain() : 'edge.etheros.ai';
    res.json({
      status: 'ok',
      service: 'isp-portal-backend',
      version: '2.0.0-multitenant',
      tenant: helpers.TENANT_SLUG || 'default',
      ispName: s.ispName || null,
      domain: s.domain || domain,
      ts: new Date().toISOString(),
    });
  });

  return router;
}

module.exports = { createAdminRouter, adminSessions };
