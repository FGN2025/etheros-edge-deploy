'use strict';
/**
 * routes/chat.js — Sprint 4R
 * POST /api/chat/stream — SSE proxy to Ollama for subscriber terminal inline chat
 *
 * Auth: Bearer token issued by /api/subscribers/auth  (base64url encoded)
 * Streams Ollama /api/chat responses as SSE to the terminal client.
 */

const express = require('express');

/**
 * @param {object} helpers  { parseToken }
 *   parseToken(token: string) → subscriberId | null
 */
function createChatRouter(helpers) {
  const { parseToken } = helpers;
  const router = express.Router();

  const OLLAMA_URL = 'http://etheros-ollama:11434/api/chat';

  // ── POST /api/chat/stream ─────────────────────────────────────────────────
  router.post('/chat/stream', async (req, res) => {
    // Validate subscriber session token
    const auth  = req.headers.authorization || '';
    const token = auth.startsWith('Bearer ') ? auth.slice(7) : '';
    const subscriberId = parseToken(token);
    if (!subscriberId) {
      return res.status(401).json({ error: 'Invalid or expired session' });
    }

    const { model, systemPrompt, messages } = req.body || {};
    if (!messages || !Array.isArray(messages)) {
      return res.status(400).json({ error: 'messages array required' });
    }

    const ollamaMessages = [
      ...(systemPrompt ? [{ role: 'system', content: systemPrompt }] : []),
      ...messages,
    ];

    const ollamaModel = model || 'llama3.1:8b';

    try {
      const upstream = await fetch(OLLAMA_URL, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ model: ollamaModel, messages: ollamaMessages, stream: true }),
      });

      if (!upstream.ok) {
        return res.status(502).json({ error: 'Ollama unavailable', status: upstream.status });
      }

      // Open SSE stream
      res.setHeader('Content-Type', 'text/event-stream');
      res.setHeader('Cache-Control', 'no-cache');
      res.setHeader('Connection', 'keep-alive');
      res.setHeader('X-Accel-Buffering', 'no');
      res.flushHeaders();

      const reader  = upstream.body.getReader();
      const decoder = new TextDecoder();

      while (true) {
        const { done, value } = await reader.read();
        if (done) break;
        const chunk = decoder.decode(value, { stream: true });
        const lines = chunk.split('\n').filter(Boolean);
        for (const line of lines) {
          try {
            const parsed = JSON.parse(line);
            const delta  = parsed.message?.content || '';
            if (delta) {
              res.write(`data: ${JSON.stringify({ choices: [{ delta: { content: delta } }] })}\n\n`);
            }
            if (parsed.done) {
              res.write('data: [DONE]\n\n');
              res.end();
              return;
            }
          } catch { /* skip malformed lines */ }
        }
      }
      res.write('data: [DONE]\n\n');
      res.end();
    } catch (err) {
      console.error('[chat/stream] error:', err.message);
      if (!res.headersSent) res.status(502).json({ error: 'Upstream error' });
      else res.end();
    }
  });

  return router;
}

module.exports = { createChatRouter };
