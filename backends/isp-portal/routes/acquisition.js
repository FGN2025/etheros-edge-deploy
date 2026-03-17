'use strict';
/**
 * routes/acquisition.js — Landing pages, lead capture, lead inbox
 * Sprint 4K
 */

const { Router } = require('express');
const { randomUUID } = require('crypto');
const { getDb, acqPageFromRow, acqLeadFromRow } = require('../db');

module.exports = function acquisitionRouter(DATA_DIR, loadSettings) {
  const router = Router();
  function db() { return getDb(DATA_DIR); }

  // ── Resend lead notification ───────────────────────────────────────────────
  async function sendLeadNotification(lead, page) {
    const s = loadSettings();
    const apiKey = (s.resendApiKey || '').trim();
    const notifyEmail = (s.resendFromEmail || s.contactEmail || 'darcy@motoworlds.com').trim();
    if (!apiKey) return { ok: false, reason: 'no_resend_key' };
    try {
      const r = await fetch('https://api.resend.com/emails', {
        method: 'POST',
        headers: { 'Authorization': `Bearer ${apiKey}`, 'Content-Type': 'application/json' },
        body: JSON.stringify({
          from: 'EtherOS Leads <noreply@etheros.ai>',
          to: [notifyEmail],
          subject: `New lead from ${page?.title || lead.pageSlug}: ${lead.name}`,
          html: `<div style="font-family:sans-serif;max-width:560px;margin:0 auto">
            <h2 style="color:#00C2CB">New EtherOS Lead</h2>
            <table style="width:100%;border-collapse:collapse">
              <tr><td style="padding:6px 0;color:#666">Name</td><td style="padding:6px 0;font-weight:600">${lead.name}</td></tr>
              <tr><td style="padding:6px 0;color:#666">Email</td><td style="padding:6px 0">${lead.email}</td></tr>
              ${lead.phone ? `<tr><td style="padding:6px 0;color:#666">Phone</td><td style="padding:6px 0">${lead.phone}</td></tr>` : ''}
              ${lead.company ? `<tr><td style="padding:6px 0;color:#666">Company</td><td style="padding:6px 0">${lead.company}</td></tr>` : ''}
              ${lead.message ? `<tr><td style="padding:6px 0;color:#666">Message</td><td style="padding:6px 0">${lead.message}</td></tr>` : ''}
              <tr><td style="padding:6px 0;color:#666">Page</td><td style="padding:6px 0">${page?.title || lead.pageSlug} (/${lead.pageSlug})</td></tr>
              <tr><td style="padding:6px 0;color:#666">Type</td><td style="padding:6px 0">${lead.leadType || 'general'}</td></tr>
              <tr><td style="padding:6px 0;color:#666">Time</td><td style="padding:6px 0">${new Date(lead.createdAt).toLocaleString()}</td></tr>
            </table>
            <p style="margin-top:20px"><a href="https://edge.etheros.ai/#/acquisition" style="background:#00C2CB;color:#0a1929;padding:10px 20px;border-radius:6px;text-decoration:none;font-weight:600">View All Leads</a></p>
          </div>`,
        }),
      });
      return { ok: r.ok, data: await r.json() };
    } catch (err) { return { ok: false, error: String(err) }; }
  }

  // ── Landing pages ─────────────────────────────────────────────────────────

  router.get('/pages', (req, res) => {
    res.json(db().prepare('SELECT * FROM acquisition_pages ORDER BY created_at DESC').all().map(acqPageFromRow));
  });

  // Public render — no auth, increments views
  router.get('/pages/:slug/render', (req, res) => {
    const d = db();
    const row = d.prepare('SELECT * FROM acquisition_pages WHERE slug=? AND published=1').get(req.params.slug);
    if (!row) return res.status(404).json({ error: 'Page not found or not published' });
    d.prepare('UPDATE acquisition_pages SET views=views+1 WHERE slug=?').run(req.params.slug);
    const updated = d.prepare('SELECT * FROM acquisition_pages WHERE slug=?').get(req.params.slug);
    res.json(acqPageFromRow(updated));
  });

  router.post('/pages', (req, res) => {
    const { title, slug, template, pageType, content, published } = req.body;
    if (!title || !slug) return res.status(400).json({ error: 'title and slug required' });
    const d = db();
    if (d.prepare('SELECT id FROM acquisition_pages WHERE slug=?').get(slug)) return res.status(409).json({ error: 'Slug already exists' });
    const now = new Date().toISOString();
    const p = {
      id: randomUUID(), title, slug, template: template||'isp-recruit',
      page_type: pageType||'isp', content: JSON.stringify(content||{}),
      published: published ? 1 : 0, views: 0, leads: 0,
      created_at: now, updated_at: now,
    };
    d.prepare(`INSERT INTO acquisition_pages
      (id,title,slug,template,page_type,content,published,views,leads,created_at,updated_at)
      VALUES (@id,@title,@slug,@template,@page_type,@content,@published,@views,@leads,@created_at,@updated_at)
    `).run(p);
    res.status(201).json(acqPageFromRow(d.prepare('SELECT * FROM acquisition_pages WHERE id=?').get(p.id)));
  });

  router.patch('/pages/:id', (req, res) => {
    const d = db();
    const row = d.prepare('SELECT * FROM acquisition_pages WHERE id=?').get(req.params.id);
    if (!row) return res.status(404).json({ error: 'Not found' });
    const b = req.body;
    if (b.slug && b.slug !== row.slug && d.prepare('SELECT id FROM acquisition_pages WHERE slug=?').get(b.slug)) {
      return res.status(409).json({ error: 'Slug already exists' });
    }
    const map = { title:'title', slug:'slug', template:'template', pageType:'page_type' };
    const sets = ['updated_at=@updated_at']; const params = { id: req.params.id, updated_at: new Date().toISOString() };
    for (const [k, v] of Object.entries(map)) {
      if (b[k] !== undefined) { sets.push(`${v}=@${v}`); params[v] = b[k]; }
    }
    if (b.content !== undefined) { sets.push('content=@content'); params.content = JSON.stringify(b.content); }
    if (b.published !== undefined) { sets.push('published=@published'); params.published = b.published ? 1 : 0; }
    d.prepare(`UPDATE acquisition_pages SET ${sets.join(',')} WHERE id=@id`).run(params);
    res.json(acqPageFromRow(d.prepare('SELECT * FROM acquisition_pages WHERE id=?').get(req.params.id)));
  });

  router.delete('/pages/:id', (req, res) => {
    const info = db().prepare('DELETE FROM acquisition_pages WHERE id=?').run(req.params.id);
    if (info.changes === 0) return res.status(404).json({ error: 'Not found' });
    res.json({ ok: true });
  });

  // ── Leads ─────────────────────────────────────────────────────────────────

  router.post('/leads', async (req, res) => {
    const { name, email, phone, company, message, pageSlug, leadType } = req.body;
    if (!name || !email || !pageSlug) return res.status(400).json({ error: 'name, email, pageSlug required' });
    const d = db();
    const now = new Date().toISOString();
    const lead = {
      id: randomUUID(), name, email, phone: phone||'', company: company||'',
      message: message||'', page_slug: pageSlug, lead_type: leadType||'general',
      status: 'new', created_at: now,
    };
    d.prepare(`INSERT INTO acquisition_leads
      (id,name,email,phone,company,message,page_slug,lead_type,status,created_at)
      VALUES (@id,@name,@email,@phone,@company,@message,@page_slug,@lead_type,@status,@created_at)
    `).run(lead);
    // Increment lead count on page
    d.prepare('UPDATE acquisition_pages SET leads=leads+1 WHERE slug=?').run(pageSlug);
    // Fire-and-forget Resend notification
    const pageRow = d.prepare('SELECT * FROM acquisition_pages WHERE slug=?').get(pageSlug);
    sendLeadNotification(acqLeadFromRow({ ...lead, page_slug: pageSlug }), pageRow ? acqPageFromRow(pageRow) : null).catch(() => {});
    res.status(201).json({ ok: true, id: lead.id });
  });

  router.get('/leads', (req, res) => {
    let q = 'SELECT * FROM acquisition_leads WHERE 1=1';
    const params = [];
    if (req.query.pageSlug) { q += ' AND page_slug=?'; params.push(req.query.pageSlug); }
    if (req.query.status)   { q += ' AND status=?';    params.push(req.query.status); }
    q += ' ORDER BY created_at DESC';
    if (req.query.limit)    { q += ' LIMIT ?'; params.push(parseInt(req.query.limit)); }
    res.json(db().prepare(q).all(...params).map(acqLeadFromRow));
  });

  router.patch('/leads/:id', (req, res) => {
    const d = db();
    const row = d.prepare('SELECT * FROM acquisition_leads WHERE id=?').get(req.params.id);
    if (!row) return res.status(404).json({ error: 'Not found' });
    const b = req.body;
    const sets = []; const params = { id: req.params.id };
    if (b.status) { sets.push('status=@status'); params.status = b.status; }
    if (sets.length > 0) d.prepare(`UPDATE acquisition_leads SET ${sets.join(',')} WHERE id=@id`).run(params);
    res.json(acqLeadFromRow(d.prepare('SELECT * FROM acquisition_leads WHERE id=?').get(req.params.id)));
  });

  return router;
};
