'use strict';
/**
 * routes/terminals.js — Terminal management + heartbeat + self-registration
 * Covers both ISP admin CRUD and terminal self-registration from edge devices.
 */

const { Router } = require('express');
const { randomUUID } = require('crypto');
const { getDb, terminalFromRow } = require('../db');

module.exports = function terminalsRouter(DATA_DIR) {
  const router = Router();

  function db() { return getDb(DATA_DIR); }

  // ── Offline timeout sweep (3-minute no-heartbeat → offline) ─────────────────
  setInterval(() => {
    try {
      const d = db();
      if (!d) return;
      const cutoff = new Date(Date.now() - 3 * 60 * 1000).toISOString();
      d.prepare(`UPDATE terminals SET status='offline' WHERE status='online' AND last_seen < ?`).run(cutoff);
    } catch {}
  }, 60_000);

  // GET /api/terminals
  router.get('/', (req, res) => {
    const rows = db().prepare('SELECT * FROM terminals ORDER BY last_seen DESC').all();
    res.json(rows.map(terminalFromRow));
  });

  // POST /api/terminals — manual admin creation
  router.post('/', (req, res) => {
    const { hostname, ip, tier, status } = req.body;
    if (!hostname || !ip) return res.status(400).json({ error: 'hostname and ip are required' });
    const t = {
      id: randomUUID(), hostname, ip,
      tier: tier || 1, status: status || 'provisioning',
      os_version: 'EtherOS 1.0', model_version: '', model_loaded: '',
      cpu_percent: 0, ram_percent: 0, disk_percent: 0,
      last_inference_ms: 0, uptime: '0m',
      last_seen: new Date().toISOString(),
      registered_at: new Date().toISOString(),
    };
    db().prepare(`INSERT INTO terminals
      (id,hostname,ip,tier,status,os_version,model_version,model_loaded,
       cpu_percent,ram_percent,disk_percent,last_inference_ms,uptime,last_seen,registered_at)
      VALUES (@id,@hostname,@ip,@tier,@status,@os_version,@model_version,@model_loaded,
              @cpu_percent,@ram_percent,@disk_percent,@last_inference_ms,@uptime,@last_seen,@registered_at)
    `).run(t);
    res.status(201).json(terminalFromRow(t));
  });

  // PATCH /api/terminals/:id
  router.patch('/:id', (req, res) => {
    const row = db().prepare('SELECT * FROM terminals WHERE id=?').get(req.params.id);
    if (!row) return res.status(404).json({ error: 'Not found' });
    const b = req.body;
    db().prepare(`UPDATE terminals SET
      hostname=COALESCE(@hostname,hostname), ip=COALESCE(@ip,ip),
      tier=COALESCE(@tier,tier), status=COALESCE(@status,status),
      os_version=COALESCE(@os_version,os_version), model_version=COALESCE(@model_version,model_version)
      WHERE id=@id
    `).run({ hostname:b.hostname||null, ip:b.ip||null, tier:b.tier||null,
             status:b.status||null, os_version:b.osVersion||null,
             model_version:b.modelVersion||null, id:req.params.id });
    const updated = db().prepare('SELECT * FROM terminals WHERE id=?').get(req.params.id);
    res.json(terminalFromRow(updated));
  });

  // DELETE /api/terminals/:id
  router.delete('/:id', (req, res) => {
    const info = db().prepare('DELETE FROM terminals WHERE id=?').run(req.params.id);
    if (info.changes === 0) return res.status(404).json({ error: 'Not found' });
    res.json({ ok: true });
  });

  // GET /api/terminals/:id — must come BEFORE register (fixed conflict from original)
  router.get('/:id', (req, res) => {
    const row = db().prepare('SELECT * FROM terminals WHERE id=?').get(req.params.id);
    if (!row) return res.status(404).json({ error: 'Not found' });
    res.json(terminalFromRow(row));
  });

  // POST /api/terminals/register — self-registration from edge device
  router.post('/register', (req, res) => {
    const { hostname, ip, osVersion, modelVersion, tier } = req.body;
    if (!hostname || !ip) return res.status(400).json({ error: 'hostname and ip are required' });
    const d = db();
    const existing = d.prepare('SELECT * FROM terminals WHERE hostname=?').get(hostname);
    if (existing) {
      d.prepare(`UPDATE terminals SET ip=?,status='online',last_seen=?,os_version=COALESCE(?,os_version),model_version=COALESCE(?,model_version) WHERE hostname=?`)
        .run(ip, new Date().toISOString(), osVersion||null, modelVersion||null, hostname);
      const updated = d.prepare('SELECT * FROM terminals WHERE hostname=?').get(hostname);
      return res.json({ ok: true, terminal: terminalFromRow(updated), registered: false });
    }
    const t = {
      id: randomUUID(), hostname, ip, tier: tier||1, status: 'provisioning',
      os_version: osVersion||'EtherOS 1.0', model_version: modelVersion||'',
      model_loaded: '', cpu_percent: 0, ram_percent: 0, disk_percent: 0,
      last_inference_ms: 0, uptime: '0m',
      last_seen: new Date().toISOString(), registered_at: new Date().toISOString(),
    };
    d.prepare(`INSERT INTO terminals
      (id,hostname,ip,tier,status,os_version,model_version,model_loaded,
       cpu_percent,ram_percent,disk_percent,last_inference_ms,uptime,last_seen,registered_at)
      VALUES (@id,@hostname,@ip,@tier,@status,@os_version,@model_version,@model_loaded,
              @cpu_percent,@ram_percent,@disk_percent,@last_inference_ms,@uptime,@last_seen,@registered_at)
    `).run(t);
    res.status(201).json({ ok: true, terminal: terminalFromRow(t), registered: true });
  });

  // POST /api/terminals/:id/heartbeat
  router.post('/:id/heartbeat', (req, res) => {
    const d = db();
    const row = d.prepare('SELECT id FROM terminals WHERE id=?').get(req.params.id);
    if (!row) return res.status(404).json({ error: 'Terminal not found — re-register' });
    const b = req.body;
    const now = new Date().toISOString();
    d.prepare(`UPDATE terminals SET
      status='online', last_seen=@now,
      cpu_percent=COALESCE(@cpu,cpu_percent),
      ram_percent=COALESCE(@ram,ram_percent),
      disk_percent=COALESCE(@disk,disk_percent),
      model_loaded=COALESCE(@model_loaded,model_loaded),
      last_inference_ms=COALESCE(@last_inf,last_inference_ms),
      uptime=COALESCE(@uptime,uptime),
      model_version=COALESCE(@model_version,model_version)
      WHERE id=@id
    `).run({
      now, id: req.params.id,
      cpu: b.cpuPercent??null, ram: b.ramPercent??null, disk: b.diskPercent??null,
      model_loaded: b.modelLoaded??null, last_inf: b.lastInferenceTime??null,
      uptime: b.uptime??null, model_version: b.modelVersion??null,
    });
    res.json({ ok: true, lastSeen: now });
  });

  return router;
};
