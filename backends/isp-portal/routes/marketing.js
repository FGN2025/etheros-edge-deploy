'use strict';
/**
 * routes/marketing.js — Campaigns, marketing pages, marketer user management
 * Sprint 4I
 */

const { Router } = require('express');
const { randomBytes } = require('crypto');
const { getDb, campaignFromRow, mktgPageFromRow } = require('../db');

function mktgId() {
  return Date.now().toString(36) + Math.random().toString(36).slice(2, 7);
}

module.exports = function marketingRouter(DATA_DIR, loadSettings) {
  const router = Router();
  function db() { return getDb(DATA_DIR); }

  function resolveMktgRole(req) {
    const adminHeader = req.headers['x-admin-token'] || '';
    const s = loadSettings();
    if (!s.adminToken || adminHeader === s.adminToken) return 'admin';
    const bearer = (req.headers.authorization || '').replace('Bearer ', '').trim();
    if (!bearer) return null;
    const user = db().prepare('SELECT id FROM marketing_users WHERE token=? AND active=1').get(bearer);
    return user ? 'marketer' : null;
  }

  function requireMktgAccess(req, res) {
    const role = resolveMktgRole(req);
    if (!role) { res.status(401).json({ error: 'Marketing auth required' }); return null; }
    return role;
  }

  // ── Marketer users ────────────────────────────────────────────────────────

  router.get('/users', (req, res) => {
    if (resolveMktgRole(req) !== 'admin') return res.status(403).json({ error: 'Admin only' });
    const rows = db().prepare('SELECT * FROM marketing_users ORDER BY created_at DESC').all();
    res.json(rows.map(r => ({ id:r.id, name:r.name, email:r.email, role:r.role, token:r.token, active:!!r.active, createdAt:r.created_at })));
  });

  router.post('/users', (req, res) => {
    if (resolveMktgRole(req) !== 'admin') return res.status(403).json({ error: 'Admin only' });
    const { name, email, role: userRole } = req.body || {};
    if (!name || !email) return res.status(400).json({ error: 'name and email required' });
    const newUser = {
      id: mktgId(), name, email, role: userRole || 'marketer',
      token: randomBytes(24).toString('hex'), active: 1,
      created_at: new Date().toISOString(),
    };
    db().prepare('INSERT INTO marketing_users (id,name,email,role,token,active,created_at) VALUES (@id,@name,@email,@role,@token,@active,@created_at)').run(newUser);
    res.json({ id:newUser.id, name:newUser.name, email:newUser.email, role:newUser.role, token:newUser.token, active:true, createdAt:newUser.created_at });
  });

  router.delete('/users/:id', (req, res) => {
    if (resolveMktgRole(req) !== 'admin') return res.status(403).json({ error: 'Admin only' });
    db().prepare('DELETE FROM marketing_users WHERE id=?').run(req.params.id);
    res.json({ ok: true });
  });

  router.get('/me', (req, res) => {
    const role = resolveMktgRole(req);
    if (!role) return res.status(401).json({ error: 'Unauthorized' });
    if (role === 'admin') return res.json({ role: 'admin', name: 'Admin' });
    const bearer = (req.headers.authorization || '').replace('Bearer ', '').trim();
    const user = db().prepare('SELECT * FROM marketing_users WHERE token=?').get(bearer);
    res.json({ role: user?.role || 'marketer', name: user?.name || 'Marketer', id: user?.id });
  });

  // ── Campaigns ─────────────────────────────────────────────────────────────

  router.get('/campaigns', (req, res) => {
    const role = requireMktgAccess(req, res);
    if (!role) return;
    let q = 'SELECT * FROM campaigns WHERE 1=1';
    const params = [];
    if (req.query.status) { q += ' AND status=?'; params.push(req.query.status); }
    if (req.query.type)   { q += ' AND type=?';   params.push(req.query.type); }
    q += ' ORDER BY created_at DESC';
    res.json(db().prepare(q).all(...params).map(campaignFromRow));
  });

  router.post('/campaigns', (req, res) => {
    const role = requireMktgAccess(req, res);
    if (!role) return;
    const { name, type, agentId, agentName, agentCategory, agentImageUrl, headline, body,
            ctaText, ctaUrl, heroImageUrl, targetPlans, scheduledAt, status } = req.body || {};
    if (!name) return res.status(400).json({ error: 'name is required' });
    let createdBy = 'admin';
    if (role !== 'admin') {
      const bearer = (req.headers.authorization || '').replace('Bearer ', '').trim();
      const user = db().prepare('SELECT id FROM marketing_users WHERE token=?').get(bearer);
      createdBy = user?.id || 'marketer';
    }
    const now = new Date().toISOString();
    const c = {
      id: mktgId(), name, type: type||'social', status: status||'draft',
      agent_id: agentId||null, agent_name: agentName||null,
      agent_category: agentCategory||null, agent_image_url: agentImageUrl||null,
      headline: headline||'', body: body||'',
      cta_text: ctaText||'Try it now', cta_url: ctaUrl||'',
      hero_image_url: heroImageUrl||agentImageUrl||null,
      target_plans: JSON.stringify(targetPlans||['personal','professional','charter']),
      scheduled_at: scheduledAt||null, created_by: createdBy,
      created_at: now, updated_at: now,
    };
    db().prepare(`INSERT INTO campaigns
      (id,name,type,status,agent_id,agent_name,agent_category,agent_image_url,headline,body,
       cta_text,cta_url,hero_image_url,target_plans,scheduled_at,created_by,created_at,updated_at)
      VALUES (@id,@name,@type,@status,@agent_id,@agent_name,@agent_category,@agent_image_url,@headline,@body,
              @cta_text,@cta_url,@hero_image_url,@target_plans,@scheduled_at,@created_by,@created_at,@updated_at)
    `).run(c);
    res.status(201).json(campaignFromRow(db().prepare('SELECT * FROM campaigns WHERE id=?').get(c.id)));
  });

  router.patch('/campaigns/:id', (req, res) => {
    const role = requireMktgAccess(req, res);
    if (!role) return;
    const d = db();
    const row = d.prepare('SELECT * FROM campaigns WHERE id=?').get(req.params.id);
    if (!row) return res.status(404).json({ error: 'Campaign not found' });
    if (role !== 'admin') {
      const bearer = (req.headers.authorization || '').replace('Bearer ', '').trim();
      const user = d.prepare('SELECT id FROM marketing_users WHERE token=?').get(bearer);
      if (row.created_by !== user?.id) return res.status(403).json({ error: 'You can only edit your own campaigns' });
    }
    const b = req.body;
    const map = { name:'name', type:'type', status:'status', headline:'headline', body:'body',
                  ctaText:'cta_text', ctaUrl:'cta_url', heroImageUrl:'hero_image_url',
                  scheduledAt:'scheduled_at', agentId:'agent_id', agentName:'agent_name' };
    const sets = ['updated_at=@updated_at']; const params = { id: req.params.id, updated_at: new Date().toISOString() };
    for (const [k, v] of Object.entries(map)) {
      if (b[k] !== undefined) { sets.push(`${v}=@${v}`); params[v] = b[k]; }
    }
    if (b.targetPlans !== undefined) { sets.push('target_plans=@target_plans'); params.target_plans = JSON.stringify(b.targetPlans); }
    d.prepare(`UPDATE campaigns SET ${sets.join(',')} WHERE id=@id`).run(params);
    res.json(campaignFromRow(d.prepare('SELECT * FROM campaigns WHERE id=?').get(req.params.id)));
  });

  router.delete('/campaigns/:id', (req, res) => {
    const role = requireMktgAccess(req, res);
    if (!role) return;
    const d = db();
    const row = d.prepare('SELECT * FROM campaigns WHERE id=?').get(req.params.id);
    if (!row) return res.status(404).json({ error: 'Campaign not found' });
    if (role !== 'admin') {
      const bearer = (req.headers.authorization || '').replace('Bearer ', '').trim();
      const user = d.prepare('SELECT id FROM marketing_users WHERE token=?').get(bearer);
      if (row.created_by !== user?.id) return res.status(403).json({ error: 'You can only delete your own campaigns' });
    }
    d.prepare('DELETE FROM campaigns WHERE id=?').run(req.params.id);
    res.json({ ok: true });
  });

  // ── Marketing pages ───────────────────────────────────────────────────────

  router.get('/pages', (req, res) => {
    const role = requireMktgAccess(req, res);
    if (!role) return;
    res.json(db().prepare('SELECT * FROM marketing_pages ORDER BY created_at DESC').all().map(mktgPageFromRow));
  });

  router.get('/pages/:slug/view', (req, res) => {
    const row = db().prepare('SELECT * FROM marketing_pages WHERE slug=? AND published=1').get(req.params.slug);
    if (!row) return res.status(404).json({ error: 'Page not found or not published' });
    const s = loadSettings();
    res.json({ ...mktgPageFromRow(row), ispName: s.ispName||'EtherOS', accentColor: s.accentColor||'#00C2CB' });
  });

  router.post('/pages', (req, res) => {
    const role = requireMktgAccess(req, res);
    if (!role) return;
    const { slug, title, heroImageUrl, headline, bodyHtml, features, ctaText, ctaUrl, agentId, agentName, published } = req.body || {};
    if (!slug || !title) return res.status(400).json({ error: 'slug and title required' });
    const d = db();
    if (d.prepare('SELECT id FROM marketing_pages WHERE slug=?').get(slug)) return res.status(409).json({ error: 'Slug already exists' });
    const now = new Date().toISOString();
    const p = {
      id: mktgId(), slug, title, hero_image_url: heroImageUrl||null,
      headline: headline||title, body_html: bodyHtml||'',
      features: JSON.stringify(features||[]), cta_text: ctaText||'Try it now',
      cta_url: ctaUrl||'/#/terminal', agent_id: agentId||null, agent_name: agentName||null,
      published: published ? 1 : 0, created_at: now, updated_at: now,
    };
    d.prepare(`INSERT INTO marketing_pages
      (id,slug,title,hero_image_url,headline,body_html,features,cta_text,cta_url,agent_id,agent_name,published,created_at,updated_at)
      VALUES (@id,@slug,@title,@hero_image_url,@headline,@body_html,@features,@cta_text,@cta_url,@agent_id,@agent_name,@published,@created_at,@updated_at)
    `).run(p);
    res.status(201).json(mktgPageFromRow(d.prepare('SELECT * FROM marketing_pages WHERE id=?').get(p.id)));
  });

  router.patch('/pages/:id', (req, res) => {
    const role = requireMktgAccess(req, res);
    if (!role) return;
    const d = db();
    const row = d.prepare('SELECT * FROM marketing_pages WHERE id=?').get(req.params.id);
    if (!row) return res.status(404).json({ error: 'Page not found' });
    const b = req.body;
    if (b.slug && b.slug !== row.slug && d.prepare('SELECT id FROM marketing_pages WHERE slug=?').get(b.slug)) {
      return res.status(409).json({ error: 'Slug already exists' });
    }
    const map = { slug:'slug', title:'title', heroImageUrl:'hero_image_url', headline:'headline',
                  bodyHtml:'body_html', ctaText:'cta_text', ctaUrl:'cta_url',
                  agentId:'agent_id', agentName:'agent_name' };
    const sets = ['updated_at=@updated_at']; const params = { id: req.params.id, updated_at: new Date().toISOString() };
    for (const [k, v] of Object.entries(map)) {
      if (b[k] !== undefined) { sets.push(`${v}=@${v}`); params[v] = b[k]; }
    }
    if (b.features !== undefined) { sets.push('features=@features'); params.features = JSON.stringify(b.features); }
    if (b.published !== undefined) { sets.push('published=@published'); params.published = b.published ? 1 : 0; }
    d.prepare(`UPDATE marketing_pages SET ${sets.join(',')} WHERE id=@id`).run(params);
    res.json(mktgPageFromRow(d.prepare('SELECT * FROM marketing_pages WHERE id=?').get(req.params.id)));
  });

  router.delete('/pages/:id', (req, res) => {
    const role = requireMktgAccess(req, res);
    if (!role) return;
    const info = db().prepare('DELETE FROM marketing_pages WHERE id=?').run(req.params.id);
    if (info.changes === 0) return res.status(404).json({ error: 'Page not found' });
    res.json({ ok: true });
  });

  return router;
};
