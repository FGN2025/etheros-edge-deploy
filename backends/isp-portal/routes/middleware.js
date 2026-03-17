'use strict';
/**
 * routes/middleware.js — Sprint 4S
 *
 * requireAdmin(adminSessions, loadSettings)
 *   Validates x-admin-token header. Returns 401 if missing/expired.
 *   Applied to all ISP admin routes.
 *
 * rateLimiter(windowMs, max)
 *   Simple in-memory rate limiter (no redis needed at this scale).
 *   Applied to login + subscriber PIN auth endpoints.
 *
 * PUBLIC routes (no auth required):
 *   GET  /health
 *   GET  /api/tenant
 *   GET  /api/terminal/config
 *   GET  /api/isp-config
 *   GET  /api/agents/browse          (terminal kiosk fetches this)
 *   POST /api/subscribers/auth       (PIN login from terminal)
 *   GET  /api/subscribers/auth/pin/:id
 *   GET  /api/acquisition/pages/:slug/render
 *   POST /api/acquisition/leads
 *   POST /api/billing/webhook        (Stripe — verified by signature)
 *   GET  /api/billing/plans          (public pricing page)
 *   GET  /api/services/blacknut/status (terminal kiosk polls this)
 */

const SESSION_TTL_MS = 8 * 60 * 60 * 1000;

// ── Admin auth middleware ─────────────────────────────────────────────────────

function requireAdmin(adminSessions, loadSettings) {
  return (req, res, next) => {
    const token = (req.headers['x-admin-token'] || '').trim();
    if (!token) return res.status(401).json({ error: 'Authentication required' });

    // Legacy: settings.adminToken fallback
    try {
      const s = loadSettings();
      if (s.adminToken && token === s.adminToken) return next();
    } catch {}

    const expiry = adminSessions.get(token);
    if (expiry && Date.now() < expiry) {
      adminSessions.set(token, Date.now() + SESSION_TTL_MS); // refresh TTL
      return next();
    }
    res.status(401).json({ error: 'Session expired or invalid' });
  };
}

// ── Simple in-memory rate limiter ─────────────────────────────────────────────

function rateLimiter(windowMs = 60_000, max = 10) {
  const hits = new Map(); // ip → [timestamps]

  // Prune old entries every 5 minutes
  setInterval(() => {
    const cutoff = Date.now() - windowMs;
    for (const [ip, times] of hits) {
      const fresh = times.filter(t => t > cutoff);
      if (fresh.length === 0) hits.delete(ip);
      else hits.set(ip, fresh);
    }
  }, 5 * 60_000);

  return (req, res, next) => {
    const ip = req.ip || req.headers['x-forwarded-for'] || 'unknown';
    const now = Date.now();
    const cutoff = now - windowMs;
    const times = (hits.get(ip) || []).filter(t => t > cutoff);
    times.push(now);
    hits.set(ip, times);
    if (times.length > max) {
      res.setHeader('Retry-After', Math.ceil(windowMs / 1000));
      return res.status(429).json({ error: 'Too many requests — please wait before trying again' });
    }
    next();
  };
}

module.exports = { requireAdmin, rateLimiter };
