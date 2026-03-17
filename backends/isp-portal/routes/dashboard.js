'use strict';
/**
 * routes/dashboard.js — Sprint 4R
 * GET /api/dashboard  — KPI aggregation
 * GET /api/server-stats — CPU / RAM / uptime
 * GET /api/revenue — revenue history
 * POST /api/revenue/snapshot — record current snapshot
 */

const express = require('express');
const fs      = require('fs');
const path    = require('path');

/**
 * @param {object} helpers  { DATA_DIR, loadSettings }
 */
function createDashboardRouter(helpers) {
  const { DATA_DIR, loadSettings } = helpers;
  const router = express.Router();

  // ── File paths (per-tenant, same as db.js schema covers) ─────────────────
  const SUBSCRIBERS_FILE = `${DATA_DIR}/subscribers.json`;
  const TERMINALS_FILE   = `${DATA_DIR}/terminals.json`;
  const AGENTS_FILE      = `${DATA_DIR}/agents.json`;
  const REVENUE_FILE     = `${DATA_DIR}/revenue-history.json`;

  function loadJSON(file, fallback = []) {
    try { return JSON.parse(fs.readFileSync(file, 'utf8')); }
    catch { return fallback; }
  }

  function loadRevenue() {
    if (fs.existsSync(REVENUE_FILE)) {
      try { return JSON.parse(fs.readFileSync(REVENUE_FILE, 'utf8')); } catch {}
    }
    // Seed zero-scaffold for last 6 months
    const now = new Date();
    const months = [];
    for (let i = 5; i >= 0; i--) {
      const d = new Date(now.getFullYear(), now.getMonth() - i, 1);
      months.push({
        month: d.toLocaleString('en-US', { month: 'short', year: 'numeric' }),
        totalRevenue: 0, ispShare: 0, agentRevenue: 0, subscriberCount: 0, seeded: true,
      });
    }
    return months;
  }

  function saveRevenue(history) {
    fs.mkdirSync(path.dirname(REVENUE_FILE), { recursive: true });
    fs.writeFileSync(REVENUE_FILE, JSON.stringify(history, null, 2));
  }

  function loadAgents() {
    try {
      const raw = fs.readFileSync(AGENTS_FILE, 'utf8');
      return JSON.parse(raw);
    } catch {
      return [];
    }
  }

  // ── GET /api/dashboard ────────────────────────────────────────────────────
  router.get('/dashboard', (req, res) => {
    const terminals   = loadJSON(TERMINALS_FILE);
    const subscribers = loadJSON(SUBSCRIBERS_FILE);
    const agents      = loadAgents();
    const revenue     = loadRevenue();

    // Terminal stats
    const online       = terminals.filter(t => t.status === 'online').length;
    const offline      = terminals.filter(t => t.status === 'offline').length;
    const provisioning = terminals.filter(t => t.status === 'provisioning').length;

    // Subscriber stats
    const activeSubs    = subscribers.filter(s => s.status === 'active');
    const monthlyRevenue = activeSubs.reduce((sum, s) => sum + (s.monthlySpend || 0), 0);
    const arpu = activeSubs.length > 0 ? (monthlyRevenue / activeSubs.length) : 0;

    // Plan distribution
    const planCounts = { personal: 0, professional: 0, charter: 0 };
    activeSubs.forEach(s => { if (planCounts[s.plan] !== undefined) planCounts[s.plan]++; });

    // Billing status breakdown
    const billingCounts = {};
    subscribers.forEach(s => {
      const status = s.billingStatus || 'invited';
      billingCounts[status] = (billingCounts[status] || 0) + 1;
    });

    // ISP breakdown — top 10 by subscriber count
    const ispMap = {};
    subscribers.forEach(s => {
      if (!s.isp) return;
      if (!ispMap[s.isp]) ispMap[s.isp] = { name: s.isp, subscribers: 0, revenue: 0 };
      ispMap[s.isp].subscribers++;
      if (s.status === 'active') ispMap[s.isp].revenue += (s.monthlySpend || 0);
    });
    const topIsps = Object.values(ispMap)
      .sort((a, b) => b.subscribers - a.subscribers)
      .slice(0, 10);

    // Agent leaderboard
    const topAgents = agents
      .filter(a => a.isEnabled)
      .sort((a, b) => (b.activationCount || 0) - (a.activationCount || 0))
      .slice(0, 8)
      .map(a => ({
        id: a.id, name: a.name, category: a.category,
        activationCount: a.activationCount || 0, pricingType: a.pricingType,
      }));

    // Agent category distribution
    const categoryMap = {};
    agents.filter(a => a.isEnabled).forEach(a => {
      categoryMap[a.category] = (categoryMap[a.category] || 0) + 1;
    });
    const agentCategories = Object.entries(categoryMap).map(([name, count]) => ({ name, count }));

    // Subscriber join trend — last 6 months
    const now = new Date();
    const joinTrend = [];
    for (let i = 5; i >= 0; i--) {
      const d = new Date(now.getFullYear(), now.getMonth() - i, 1);
      const label = d.toLocaleString('en-US', { month: 'short', year: '2-digit' });
      const count = subscribers.filter(s => {
        if (!s.joinedAt) return false;
        const j = new Date(s.joinedAt);
        return j.getFullYear() === d.getFullYear() && j.getMonth() === d.getMonth();
      }).length;
      joinTrend.push({ month: label, subscribers: count });
    }

    // Churn signals
    const thirtyDaysAgo = Date.now() - 30 * 24 * 60 * 60 * 1000;
    const stalledInvites = subscribers.filter(s =>
      s.billingStatus === 'invited' &&
      s.billingInvitedAt &&
      new Date(s.billingInvitedAt).getTime() < thirtyDaysAgo
    ).length;
    const pastDue      = subscribers.filter(s => s.billingStatus === 'past_due').length;
    const cancelPending = subscribers.filter(s => s.cancelAtPeriodEnd).length;

    // Revenue history (last 6 months)
    const revenueByMonth = revenue.slice(-6);
    const prevMonthlyRevenue = revenueByMonth.length >= 2
      ? revenueByMonth[revenueByMonth.length - 2].totalRevenue
      : Math.round(monthlyRevenue * 0.95);

    // Recent activity — terminals last seen
    const recentTerminals = [...terminals]
      .filter(t => t.lastSeen)
      .sort((a, b) => new Date(b.lastSeen) - new Date(a.lastSeen))
      .slice(0, 5)
      .map(t => ({
        id: t.id,
        type: 'terminal',
        message: `${t.hostname || t.id} — ${t.status}`,
        timestamp: t.lastSeen,
      }));

    res.json({
      totalTerminals: terminals.length,
      online, offline, provisioning,
      activeSubscribers: activeSubs.length,
      totalSubscribers: subscribers.length,
      monthlyRevenue,
      prevMonthlyRevenue,
      arpu,
      planDistribution: [
        { name: 'Personal',     value: planCounts.personal,     color: '#00C2CB' },
        { name: 'Professional', value: planCounts.professional, color: '#00A8B0' },
        { name: 'Charter',      value: planCounts.charter,      color: '#007A80' },
      ],
      billingCounts,
      stalledInvites,
      pastDue,
      cancelPending,
      topIsps,
      topAgents,
      agentCategories,
      totalAgents: agents.filter(a => a.isEnabled).length,
      joinTrend,
      revenueByMonth,
      activity: recentTerminals,
    });
  });

  // ── GET /api/server-stats ─────────────────────────────────────────────────
  router.get('/server-stats', (req, res) => {
    const osLib = require('os');
    const totalMem = osLib.totalmem();
    const freeMem  = osLib.freemem();
    const usedMem  = totalMem - freeMem;
    const cpus     = osLib.cpus();

    const cpuUsage = cpus.map(cpu => {
      const times = cpu.times;
      const total = Object.values(times).reduce((a, b) => a + b, 0);
      const idle  = times.idle;
      return total > 0 ? Math.round(((total - idle) / total) * 100) : 0;
    });
    const avgCpu = cpuUsage.length > 0
      ? Math.round(cpuUsage.reduce((a, b) => a + b, 0) / cpuUsage.length)
      : 0;

    const uptimeSecs  = osLib.uptime();
    const uptimeDays  = Math.floor(uptimeSecs / 86400);
    const uptimeHours = Math.floor((uptimeSecs % 86400) / 3600);
    const uptimeStr   = uptimeDays > 0 ? `${uptimeDays}d ${uptimeHours}h` : `${uptimeHours}h`;
    const load        = osLib.loadavg();
    const procMem     = process.memoryUsage();

    res.json({
      cpu: {
        cores: cpus.length,
        model: cpus[0]?.model || 'Unknown',
        usagePercent: avgCpu,
        perCore: cpuUsage,
        loadAvg: load.map(l => Math.round(l * 100) / 100),
      },
      memory: {
        totalGb:     Math.round((totalMem / 1073741824) * 10) / 10,
        usedGb:      Math.round((usedMem  / 1073741824) * 10) / 10,
        freeGb:      Math.round((freeMem  / 1073741824) * 10) / 10,
        usedPercent: Math.round((usedMem / totalMem) * 100),
      },
      process: {
        heapUsedMb:  Math.round(procMem.heapUsed  / 1048576),
        heapTotalMb: Math.round(procMem.heapTotal / 1048576),
        rssMb:       Math.round(procMem.rss       / 1048576),
      },
      uptime: uptimeStr,
      uptimeSecs,
      platform: osLib.platform(),
      nodeVersion: process.version,
      ts: new Date().toISOString(),
    });
  });

  // ── GET /api/revenue ──────────────────────────────────────────────────────
  router.get('/revenue', (req, res) => {
    res.json(loadRevenue());
  });

  // ── POST /api/revenue/snapshot ────────────────────────────────────────────
  router.post('/revenue/snapshot', (req, res) => {
    const subs    = loadJSON(SUBSCRIBERS_FILE);
    const active  = subs.filter(s => s.status === 'active');
    const totalRevenue  = Math.round(active.reduce((s, sub) => s + (sub.monthlySpend || 0), 0));
    const agentRevenue  = Math.round(active.reduce((s, sub) => s + ((sub.agentsActive || 0) * 4.99), 0));
    const ispShare      = Math.round(totalRevenue * 0.3);
    const month = new Date().toLocaleString('en-US', {
      month: 'short', year: 'numeric', timeZone: 'America/Phoenix',
    });
    const snap = { month, totalRevenue, ispShare, agentRevenue, subscriberCount: active.length };
    const history = loadRevenue();
    const idx = history.findIndex(r => r.month === month);
    if (idx >= 0) history[idx] = snap; else history.push(snap);
    history.sort((a, b) => new Date('1 ' + a.month) - new Date('1 ' + b.month));
    saveRevenue(history.slice(-24));
    res.json(snap);
  });

  return router;
}

module.exports = { createDashboardRouter };
