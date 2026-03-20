'use strict';
/**
 * routes/email.js — Transactional email helpers via Resend
 * Sprint 4V
 *
 * All functions are fire-and-forget friendly (they never throw).
 * API key sourced from: process.env.RESEND_API_KEY → settings.resendApiKey
 * From address:         process.env.RESEND_FROM_EMAIL → settings.resendFromEmail → 'EtherOS <noreply@etheros.ai>'
 */

const RESEND_API = 'https://api.resend.com/emails';

function getResendKey(loadSettings) {
  return (process.env.RESEND_API_KEY || (loadSettings().resendApiKey || '')).trim();
}

function getFromAddress(loadSettings) {
  return (process.env.RESEND_FROM_EMAIL || (loadSettings().resendFromEmail || '')).trim()
    || 'EtherOS <noreply@etheros.ai>';
}

/**
 * Low-level send. Returns { ok, id?, error? }. Never throws.
 */
async function sendEmail({ to, subject, html, loadSettings }) {
  const apiKey = getResendKey(loadSettings);
  if (!apiKey) {
    console.warn('[email] Resend API key not configured — email not sent');
    return { ok: false, reason: 'no_resend_key' };
  }
  try {
    const r = await fetch(RESEND_API, {
      method: 'POST',
      headers: { 'Authorization': `Bearer ${apiKey}`, 'Content-Type': 'application/json' },
      body: JSON.stringify({ from: getFromAddress(loadSettings), to: Array.isArray(to) ? to : [to], subject, html }),
    });
    const data = await r.json();
    if (!r.ok) {
      console.error('[email] Resend error:', data);
      return { ok: false, error: data.message || 'Resend API error' };
    }
    return { ok: true, id: data.id };
  } catch (err) {
    console.error('[email] sendEmail failed:', err);
    return { ok: false, error: String(err) };
  }
}

// ── Email templates ────────────────────────────────────────────────────────────

/**
 * Welcome + PIN email sent immediately after subscriber account creation.
 * Used for both free (no Stripe) and paid (Stripe checkout) signup paths.
 */
async function sendPinWelcomeEmail({ subscriber, pin, ispName, terminalUrl, loadSettings }) {
  const name = subscriber.name || 'there';
  const isp  = ispName || 'EtherOS';
  const url  = terminalUrl || 'https://edge.etheros.ai';

  const html = `
<div style="font-family:system-ui,sans-serif;max-width:520px;margin:0 auto;background:#0a1929;color:#e2e8f0;border-radius:12px;overflow:hidden">
  <div style="background:linear-gradient(135deg,#00C2CB22,#0a1929);padding:32px 32px 24px;border-bottom:1px solid #ffffff15">
    <p style="margin:0 0 4px;font-size:11px;text-transform:uppercase;letter-spacing:.1em;color:#00C2CB">Welcome to</p>
    <h1 style="margin:0;font-size:22px;font-weight:700;color:#ffffff">${isp}</h1>
  </div>

  <div style="padding:32px">
    <p style="margin:0 0 20px;font-size:15px;color:#94a3b8">Hi ${name},</p>
    <p style="margin:0 0 28px;font-size:15px;color:#94a3b8;line-height:1.6">
      Your EtherOS terminal account is ready. Use the PIN below every time you sign in — no password needed.
    </p>

    <div style="background:#ffffff08;border:1px solid #ffffff18;border-radius:10px;padding:24px;text-align:center;margin-bottom:28px">
      <p style="margin:0 0 8px;font-size:11px;text-transform:uppercase;letter-spacing:.12em;color:#64748b">Your Terminal PIN</p>
      <p style="margin:0;font-size:36px;font-weight:700;letter-spacing:.5em;font-family:ui-monospace,monospace;color:#ffffff">${pin}</p>
    </div>

    <p style="margin:0 0 24px;font-size:13px;color:#64748b;text-align:center">
      Keep this PIN safe — treat it like a password.
    </p>

    <div style="text-align:center">
      <a href="${url}" style="display:inline-block;background:#00C2CB;color:#0a1929;font-weight:700;font-size:14px;padding:12px 28px;border-radius:8px;text-decoration:none">
        Open My Terminal →
      </a>
    </div>
  </div>

  <div style="padding:16px 32px;border-top:1px solid #ffffff10;text-align:center">
    <p style="margin:0;font-size:11px;color:#334155">
      Powered by <a href="https://etheros.ai" style="color:#00C2CB;text-decoration:none">EtherOS</a>
      · <a href="${url}" style="color:#475569;text-decoration:none">${url}</a>
    </p>
  </div>
</div>`;

  return sendEmail({
    to: subscriber.email,
    subject: `Your ${isp} terminal PIN`,
    html,
    loadSettings,
  });
}

/**
 * PIN reminder / recovery email. Same template as welcome but different copy.
 */
async function sendPinRecoveryEmail({ subscriber, pin, ispName, terminalUrl, loadSettings }) {
  const name = subscriber.name || 'there';
  const isp  = ispName || 'EtherOS';
  const url  = terminalUrl || 'https://edge.etheros.ai';

  const html = `
<div style="font-family:system-ui,sans-serif;max-width:520px;margin:0 auto;background:#0a1929;color:#e2e8f0;border-radius:12px;overflow:hidden">
  <div style="background:linear-gradient(135deg,#00C2CB22,#0a1929);padding:32px 32px 24px;border-bottom:1px solid #ffffff15">
    <p style="margin:0 0 4px;font-size:11px;text-transform:uppercase;letter-spacing:.1em;color:#00C2CB">${isp}</p>
    <h1 style="margin:0;font-size:22px;font-weight:700;color:#ffffff">PIN Recovery</h1>
  </div>

  <div style="padding:32px">
    <p style="margin:0 0 20px;font-size:15px;color:#94a3b8">Hi ${name},</p>
    <p style="margin:0 0 28px;font-size:15px;color:#94a3b8;line-height:1.6">
      You requested your terminal PIN. Here it is:
    </p>

    <div style="background:#ffffff08;border:1px solid #ffffff18;border-radius:10px;padding:24px;text-align:center;margin-bottom:28px">
      <p style="margin:0 0 8px;font-size:11px;text-transform:uppercase;letter-spacing:.12em;color:#64748b">Your Terminal PIN</p>
      <p style="margin:0;font-size:36px;font-weight:700;letter-spacing:.5em;font-family:ui-monospace,monospace;color:#ffffff">${pin}</p>
    </div>

    <p style="margin:0 0 24px;font-size:13px;color:#64748b;text-align:center">
      If you didn't request this, no action is needed — your PIN has not changed.
    </p>

    <div style="text-align:center">
      <a href="${url}" style="display:inline-block;background:#00C2CB;color:#0a1929;font-weight:700;font-size:14px;padding:12px 28px;border-radius:8px;text-decoration:none">
        Sign In Now →
      </a>
    </div>
  </div>

  <div style="padding:16px 32px;border-top:1px solid #ffffff10;text-align:center">
    <p style="margin:0;font-size:11px;color:#334155">
      Powered by <a href="https://etheros.ai" style="color:#00C2CB;text-decoration:none">EtherOS</a>
      · <a href="${url}" style="color:#475569;text-decoration:none">${url}</a>
    </p>
  </div>
</div>`;

  return sendEmail({
    to: subscriber.email,
    subject: `Your ${isp} terminal PIN`,
    html,
    loadSettings,
  });
}

module.exports = { sendEmail, sendPinWelcomeEmail, sendPinRecoveryEmail };
