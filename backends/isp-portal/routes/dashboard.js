'use strict';
/**
 * routes/dashboard.js — Sprint 4S
 * GET /api/dashboard  — KPI aggregation (reads from SQLite)
 * GET /api/server-stats — CPU / RAM / uptime
 * GET /api/revenue — revenue history
 * POST /api/revenue/snapshot — record current snapshot
 */

const express = require('express');
const fs      = require('fs');
const path    = require('path');
const { getDb } = require('../db');

function createDashboardRouter(helpers) {
  const { DATA_DIR } = helpers;
  const router = express.Router();

  // ── Revenue history (JSON file — append-only log, not migrated to SQLite) ──
  const REVENUE_FILE = `${DATA_DIR}/revenue-history.json`;

  function loadRevenue() {
    if (fs.existsSync(REVENUE_FILE)) {
      try { return JSON.parse(fs.readFileSync(REVENUE_FILE, 'utf8')); } catch {}
    }
    const now = new Date();
    return Array.from({ length: 6 }, (_, i) => {
      const d = new Date(now.getFullYear(), now.getMonth() - (5 - i), 1);
      return { month: d.toLocaleString('en-US', { month: 'short', year: 'numeric' }), totalRevenue: 0, ispShare: 0, agentRevenue: 0, subscriberCount: 0, seeded: true };
    });
  }
  function saveRevenue(history) {
    fs.mkdirSync(path.dirname(REVENUE_FILE), { recursive: true });
    fs.writeFileSync(REVENUE_FILE, JSON.stringify(history, null, 2));
  }

  // ── GET /api/dashboard ────────────────────────────────────────────────────
  router.get('/dashboard', (req, res) => {
    try {
      const db = getDb(DATA_DIR);

      // ── Terminal stats ──────────────────────────────────────────────────
      const termRows    = db.prepare('SELECT status FROM terminals').all();
      const online       = termRows.filter(t => t.status === 'online').length;
      const offline      = termRows.filter(t => t.status === 'offline').length;
      const provisioning = termRows.filter(t => t.status === 'provisioning').length;

      // ── Subscriber stats ────────────────────────────────────────────────
      const subRows      = db.prepare('SELECT plan, status, monthly_spend, joined_at, isp, billing_status, billing_invited_at, cancel_at_period_end FROM subscribers').all();
      const activeSubs   = subRows.filter(s => s.status === 'active');
      const monthlyRevenue = activeSubs.reduce((sum, s) => sum + (s.monthly_spend || 0), 0);
      const arpu = activeSubs.length > 0 ? (monthlyRevenue / activeSubs.length) : 0;

      // Plan distribution
      const planCounts = { personal: 0, professional: 0, charter: 0 };
      activeSubs.forEach(s => { if (planCounts[s.plan] !== undefined) planCounts[s.plan]++; });

      // Billing status breakdown
      const billingCounts = {};
      subRows.forEach(s => {
        const status = s.billing_status || 'invited';
        billingCounts[status] = (billingCounts[status] || 0) + 1;
      });

      // ISP breakdown — top 10 by subscriber count
      const ispMap = {};
      subRows.forEach(s => {
        if (!s.isp) return;
        if (!ispMap[s.isp]) ispMap[s.isp] = { name: s.isp, subscribers: 0, revenue: 0 };
        ispMap[s.isp].subscribers++;
        if (s.status === 'active') ispMap[s.isp].revenue += (s.monthly_spend || 0);
      });
      const topIsps = Object.values(ispMap).sort((a, b) => b.subscribers - a.subscribers).slice(0, 10);

      // ── Agent stats ─────────────────────────────────────────────────────
      const agentRows = db.prepare('SELECT id, name, category, pricing_type, is_enabled, activation_count FROM agents').all();
      const topAgents = agentRows
        .filter(a => a.is_enabled)
        .sort((a, b) => (b.activation_count || 0) - (a.activation_count || 0))
        .slice(0, 8)
        .map(a => ({ id: a.id, name: a.name, category: a.category, activationCount: a.activation_count || 0, pricingType: a.pricing_type }));

      const categoryMap = {};
      agentRows.filter(a => a.is_enabled).forEach(a => {
        categoryMap[a.category] = (categoryMap[a.category] || 0) + 1;
      });
      const agentCategories = Object.entries(categoryMap).map(([name, count]) => ({ name, count }));

      // ── Subscriber join trend — last 6 months ───────────────────────────
      const now = new Date();
      const joinTrend = Array.from({ length: 6 }, (_, i) => {
        const d = new Date(now.getFullYear(), now.getMonth() - (5 - i), 1);
        const label = d.toLocaleString('en-US', { month: 'short', year: '2-digit' });
        const count = subRows.filter(s => {
          if (!s.joined_at) return false;
          const j = new Date(s.joined_at);
          return j.getFullYear() === d.getFullYear() && j.getMonth() === d.getMonth();
        }).length;
        return { month: label, subscribers: count };
      });

      // ── Churn signals ────────────────────────────────────────────────────
      const thirtyDaysAgo = new Date(Date.now() - 30 * 24 * 60 * 60 * 1000).toISOString();
      const stalledInvites = subRows.filter(s =>
        s.billing_status === 'invited' && s.billing_invited_at && s.billing_invited_at < thirtyDaysAgo
      ).length;
      const pastDue      = subRows.filter(s => s.billing_status === 'past_due').length;
      const cancelPending = subRows.filter(s => s.cancel_at_period_end).length;

      // ── Revenue history ──────────────────────────────────────────────────
      const revenue = loadRevenue();
      const revenueByMonth = revenue.slice(-6);
      const prevMonthlyRevenue = revenueByMonth.length >= 2
        ? revenueByMonth[revenueByMonth.length - 2].totalRevenue
        : Math.round(monthlyRevenue * 0.95);

      // ── Recent terminal activity ─────────────────────────────────────────
      const recentTerminals = db.prepare(
        'SELECT id, hostname, status, last_seen FROM terminals WHERE last_seen IS NOT NULL ORDER BY last_seen DESC LIMIT 5'
      ).all().map(t => ({
        id: t.id, type: 'terminal',
        message: `${t.hostname || t.id} — ${t.status}`,
        timestamp: t.last_seen,
      }));

      res.json({
        totalTerminals: termRows.length,
        online, offline, provisioning,
        activeSubscribers: activeSubs.length,
        totalSubscribers: subRows.length,
        monthlyRevenue,
        prevMonthlyRevenue,
        arpu,
        planDistribution: [
          { name: 'Personal',     value: planCounts.personal,     color: '#00C2CB' },
          { name: 'Professional', value: planCounts.professional, color: '#00A8B0' },
          { name: 'Charter',      value: planCounts.charter,      color: '#007A80' },
        ],
        billingCounts, stalledInvites, pastDue, cancelPending,
        topIsps, topAgents, agentCategories,
        totalAgents: agentRows.filter(a => a.is_enabled).length,
        joinTrend, revenueByMonth,
        activity: recentTerminals,
      });
    } catch (err) {
      console.error('[dashboard] error:', err.message);
      res.status(500).json({ error: 'Dashboard unavailable', detail: err.message });
    }
  });

  // ── GET /api/server-stats ─────────────────────────────────────────────────
  router.get('/server-stats', (req, res) => {
    const osLib = require('os');
    const totalMem = osLib.totalmem();
    const freeMem  = osLib.freemem();
    const usedMem  = totalMem - freeMem;
    const cpus     = osLib.cpus();
    const cpuUsage = cpus.map(cpu => {
      const total = Object.values(cpu.times).reduce((a, b) => a + b, 0);
      return total > 0 ? Math.round(((total - cpu.times.idle) / total) * 100) : 0;
    });
    const avgCpu = cpuUsage.length > 0 ? Math.round(cpuUsage.reduce((a, b) => a + b, 0) / cpuUsage.length) : 0;
    const uptimeSecs  = osLib.uptime();
    const uptimeDays  = Math.floor(uptimeSecs / 86400);
    const uptimeHours = Math.floor((uptimeSecs % 86400) / 3600);
    const procMem = process.memoryUsage();
    res.json({
      cpu: { cores: cpus.length, model: cpus[0]?.model || 'Unknown', usagePercent: avgCpu, perCore: cpuUsage, loadAvg: osLib.loadavg().map(l => Math.round(l * 100) / 100) },
      memory: { totalGb: Math.round((totalMem / 1073741824) * 10) / 10, usedGb: Math.round((usedMem / 1073741824) * 10) / 10, freeGb: Math.round((freeMem / 1073741824) * 10) / 10, usedPercent: Math.round((usedMem / totalMem) * 100) },
      process: { heapUsedMb: Math.round(procMem.heapUsed / 1048576), heapTotalMb: Math.round(procMem.heapTotal / 1048576), rssMb: Math.round(procMem.rss / 1048576) },
      uptime: uptimeDays > 0 ? `${uptimeDays}d ${uptimeHours}h` : `${uptimeHours}h`,
      uptimeSecs, platform: osLib.platform(), nodeVersion: process.version, ts: new Date().toISOString(),
    });
  });

  // ── GET /api/revenue ──────────────────────────────────────────────────────
  router.get('/revenue', (req, res) => res.json(loadRevenue()));

  // ── POST /api/revenue/snapshot ────────────────────────────────────────────
  router.post('/revenue/snapshot', (req, res) => {
    try {
      const db = getDb(DATA_DIR);
      const active = db.prepare("SELECT monthly_spend, agents_active FROM subscribers WHERE status='active'").all();
      const totalRevenue  = Math.round(active.reduce((s, sub) => s + (sub.monthly_spend || 0), 0));
      const agentRevenue  = Math.round(active.reduce((s, sub) => s + ((sub.agents_active || 0) * 4.99), 0));
      const ispShare      = Math.round(totalRevenue * 0.3);
      const month = new Date().toLocaleString('en-US', { month: 'short', year: 'numeric', timeZone: 'America/Phoenix' });
      const snap = { month, totalRevenue, ispShare, agentRevenue, subscriberCount: active.length };
      const history = loadRevenue();
      const idx = history.findIndex(r => r.month === month);
      if (idx >= 0) history[idx] = snap; else history.push(snap);
      history.sort((a, b) => new Date('1 ' + a.month) - new Date('1 ' + b.month));
      saveRevenue(history.slice(-24));
      res.json(snap);
    } catch (err) {
      res.status(500).json({ error: String(err) });
    }
  });

  return router;
}

module.exports = { createDashboardRouter };
