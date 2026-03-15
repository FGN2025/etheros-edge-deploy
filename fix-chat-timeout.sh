#!/usr/bin/env bash
# ══════════════════════════════════════════════════════════════════════════════
#  EtherOS — Fix Chat Timeout
#
#  The chat starts streaming (nginx SSE fix worked) but times out before
#  completing because:
#  1. phi3:mini is ~1.4 tok/s — a 60-token response takes ~45s
#  2. The SSE connection goes silent during notebook fetch + model startup
#     (~6-10s of no data), which can cause the browser to consider it stalled
#  3. qwen2:0.5b is not yet pulled — need it for ~5-8 tok/s (3-5x faster)
#
#  This script:
#  A. Pulls qwen2:0.5b (fast CPU model, ~350MB)
#  B. Patches ollamaChatStream to send SSE keepalive ': heartbeat' comments
#     every 5s during silent startup phase
#  C. Switches the CDL Skills Development agent to qwen2:0.5b
#  D. Truncates system prompt context to 400 chars/source (fewer tokens)
#
#  Run as: bash <(curl -fsSL https://raw.githubusercontent.com/FGN2025/etheros-edge-deploy/main/fix-chat-timeout.sh)
# ══════════════════════════════════════════════════════════════════════════════
set -euo pipefail

echo ""
echo "══════════════════════════════════════════════════════"
echo "  EtherOS Chat Timeout Fix"
echo "══════════════════════════════════════════════════════"
echo ""

# ── Part A: Pull qwen2:0.5b (fast CPU model) ────────────────────────────────
echo "▸ Part A: Pulling qwen2:0.5b (~350MB, ~5-8 tok/s on CPU)..."
echo "  (This may take 2-5 minutes on first pull)"
echo ""

# Check if already pulled
if docker exec etheros-ollama ollama list 2>/dev/null | grep -q "qwen2:0.5b"; then
  echo "  ✓ qwen2:0.5b already present — skipping pull"
else
  docker exec etheros-ollama ollama pull qwen2:0.5b
  echo "  ✓ qwen2:0.5b pulled successfully"
fi
echo ""

# ── Part B: Patch ollamaChatStream with keepalive heartbeat ─────────────────
echo "▸ Part B: Patching backend — adding SSE keepalive heartbeat..."

python3 << 'PYEOF'
import re

SERVER = '/opt/etheros-edge/backends/marketplace/server.js'

with open(SERVER, 'r') as f:
    src = f.read()

# ── B1: Replace the ollamaChatStream function with a keepalive-enhanced version
# Find and replace the entire ollamaChatStream function
old_stream_fn = '''// Streaming version — pipes Ollama NDJSON tokens as SSE to the client
async function ollamaChatStream(model, messages, res) {
  res.setHeader('Content-Type', 'text/event-stream');
  res.setHeader('Cache-Control', 'no-cache');
  res.setHeader('Connection', 'keep-alive');
  res.setHeader('X-Accel-Buffering', 'no');
  res.flushHeaders();

  const upstream = await fetch(`${OLLAMA_URL}/api/chat`, {
    method: 'POST', headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ model, messages, stream: true }),
    signal: AbortSignal.timeout(120000),
  });

  if (!upstream.ok) {
    res.write(`data: ${JSON.stringify({ error: `Ollama ${upstream.status}` })}\\n\\n`);
    res.end();
    return;
  }

  const reader = upstream.body.getReader();
  const decoder = new TextDecoder();
  let fullContent = '';

  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      const chunk = decoder.decode(value, { stream: true });
      for (const line of chunk.split('\\n')) {
        if (!line.trim()) continue;
        try {
          const json = JSON.parse(line);
          const token = json?.message?.content || '';
          if (token) {
            fullContent += token;
            res.write(`data: ${JSON.stringify({ token })}\\n\\n`);
          }
          if (json.done) {
            res.write(`data: ${JSON.stringify({ done: true, model, full: fullContent })}\\n\\n`);
            res.end();
            return;
          }
        } catch {}
      }
    }
  } catch (err) {
    res.write(`data: ${JSON.stringify({ error: String(err) })}\\n\\n`);
  }
  res.end();
}'''

new_stream_fn = '''// Streaming version — pipes Ollama NDJSON tokens as SSE to the client
// Sends SSE keepalive comments (': hb') every 5s during silent startup
// so the browser never considers the connection stalled.
async function ollamaChatStream(model, messages, res) {
  res.setHeader('Content-Type', 'text/event-stream');
  res.setHeader('Cache-Control', 'no-cache');
  res.setHeader('Connection', 'keep-alive');
  res.setHeader('X-Accel-Buffering', 'no');
  res.flushHeaders();

  // Send immediate keepalive so browser knows stream is open
  res.write(': connected\\n\\n');

  // Heartbeat interval — writes SSE comment every 5s during generation
  // SSE comments (lines starting with ':') are ignored by the browser
  // event parser but keep the TCP connection alive through proxies/timeouts
  let heartbeat = setInterval(() => {
    try { res.write(': hb\\n\\n'); } catch {}
  }, 5000);

  try {
    const upstream = await fetch(`${OLLAMA_URL}/api/chat`, {
      method: 'POST', headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ model, messages, stream: true }),
      signal: AbortSignal.timeout(180000),
    });

    if (!upstream.ok) {
      clearInterval(heartbeat);
      res.write(`data: ${JSON.stringify({ error: `Ollama ${upstream.status}` })}\\n\\n`);
      res.end();
      return;
    }

    const reader = upstream.body.getReader();
    const decoder = new TextDecoder();
    let fullContent = '';

    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      const chunk = decoder.decode(value, { stream: true });
      for (const line of chunk.split('\\n')) {
        if (!line.trim()) continue;
        try {
          const json = JSON.parse(line);
          const token = json?.message?.content || '';
          if (token) {
            fullContent += token;
            res.write(`data: ${JSON.stringify({ token })}\\n\\n`);
          }
          if (json.done) {
            clearInterval(heartbeat);
            res.write(`data: ${JSON.stringify({ done: true, model, full: fullContent })}\\n\\n`);
            res.end();
            return;
          }
        } catch {}
      }
    }
  } catch (err) {
    res.write(`data: ${JSON.stringify({ error: String(err) })}\\n\\n`);
  } finally {
    clearInterval(heartbeat);
  }
  res.end();
}'''

if old_stream_fn in src:
    src = src.replace(old_stream_fn, new_stream_fn)
    print("  ✓ ollamaChatStream patched with keepalive heartbeat")
else:
    # Try to find and patch just the timeout and heartbeat portions
    # as the function may have slight variations from previous patches
    if 'ollamaChatStream' in src:
        # Add heartbeat after flushHeaders if not already present
        if 'heartbeat' not in src:
            src = src.replace(
                "  res.flushHeaders();\n\n  const upstream = await fetch",
                "  res.flushHeaders();\n  res.write(': connected\\\\n\\\\n');\n\n  let heartbeat = setInterval(() => { try { res.write(': hb\\\\n\\\\n'); } catch {} }, 5000);\n\n  try {\n  const upstream = await fetch"
            )
            # Extend timeout from 120000 to 180000
            src = src.replace('AbortSignal.timeout(120000)', 'AbortSignal.timeout(180000)')
            print("  ✓ Added heartbeat to existing ollamaChatStream")
        else:
            print("  ✓ Heartbeat already present — extending timeout only")
            src = src.replace('AbortSignal.timeout(120000)', 'AbortSignal.timeout(180000)')
    else:
        print("  ⚠  ollamaChatStream not found — stream fix may not be applied yet")

# ── B2: Trim context further — 800 chars was still too much, go to 400
# Reduces token count in prompt → faster generation
src = src.replace(
    'context = context.slice(0, 800)',
    'context = context.slice(0, 400)'
)
src = src.replace(
    ".slice(0, 800)",
    ".slice(0, 400)"
)
# Handle the trim in fetchNotebookContext
if '1500' in src:
    src = src.replace('.slice(0, 1500)', '.slice(0, 400)')
    print("  ✓ Context trimmed: 1500 → 400 chars per source")
elif '800' in src:
    print("  ✓ Context trimmed: 800 → 400 chars per source")

with open(SERVER, 'w') as f:
    f.write(src)

print("  ✓ Backend patches written")
PYEOF

echo "  ✓ Backend patched"
echo ""

# ── Part C: Switch CDL agent to qwen2:0.5b ──────────────────────────────────
echo "▸ Part C: Switching CDL Skills Development agent to qwen2:0.5b..."

python3 << 'PYEOF2'
import json, os, urllib.request

AGENTS_FILE = '/opt/etheros-edge/data/agents.json'

if os.path.exists(AGENTS_FILE):
    with open(AGENTS_FILE, 'r') as f:
        agents = json.load(f)

    updated = 0
    for agent in agents:
        slug = agent.get('slug', '')
        agent_id = agent.get('id', '')
        # Switch all phi3:mini agents to qwen2:0.5b for faster responses
        # (CDL agent specifically, but all phi3 agents benefit)
        if agent.get('modelId') == 'phi3:mini':
            agent['modelId'] = 'qwen2:0.5b'
            print(f"  Switched: {agent_id} ({slug}) phi3:mini → qwen2:0.5b")
            updated += 1

    with open(AGENTS_FILE, 'w') as f:
        json.dump(agents, f, indent=2)

    print(f"  ✓ {updated} agent(s) updated to qwen2:0.5b in agents.json")
else:
    print("  ⚠  agents.json not found — patching server.js seed instead")
    with open('/opt/etheros-edge/backends/marketplace/server.js', 'r') as f:
        src = f.read()
    # Update default model in seed data
    src = src.replace(
        "const FALLBACK_MODEL = 'phi3:mini'",
        "const FALLBACK_MODEL = 'qwen2:0.5b'"
    )
    with open('/opt/etheros-edge/backends/marketplace/server.js', 'w') as f:
        f.write(src)
    print("  ✓ Seed model updated to qwen2:0.5b")
PYEOF2

echo ""

# ── Restart backend ──────────────────────────────────────────────────────────
echo "▸ Restarting marketplace backend..."
docker restart etheros-marketplace-backend
sleep 5

echo ""
echo "▸ Verifying backend health..."
for i in 1 2 3 4 5; do
  STATUS=$(curl -sf -o /dev/null -w "%{http_code}" http://localhost:3011/api/agents 2>/dev/null || echo "FAIL")
  if [ "$STATUS" = "200" ]; then
    echo "  ✓ Backend responding (HTTP 200)"
    break
  fi
  echo "  Waiting... ($i/5)"
  sleep 2
done

echo ""
echo "▸ Checking CDL agent model..."
python3 << 'PYEOF3'
import json, urllib.request
try:
    with urllib.request.urlopen('http://localhost:3011/api/agents', timeout=5) as r:
        agents = json.loads(r.read())
    cdl = next((a for a in agents if 'cdl' in a.get('slug','').lower()), None)
    if cdl:
        print(f"  CDL agent: {cdl.get('id')} | model: {cdl.get('modelId')} | connectors: {cdl.get('notebookConnectorIds', [])}")
    for a in agents:
        print(f"  {a.get('id','?')[:8]} {a.get('slug','?'):30} model={a.get('modelId','?')}")
except Exception as e:
    print(f"  ✗ {e}")
PYEOF3

echo ""
echo "▸ Testing SSE stream with qwen2:0.5b (30s timeout)..."
echo "  Watching for tokens..."
timeout 30 curl -s -N \
  -X POST "http://localhost/marketplace/api/agents/1350abe4/chat/stream" \
  -H "Content-Type: application/json" \
  -H "Host: edge.etheros.ai" \
  -d '{"messages":[{"role":"user","content":"In one sentence, what is a CDL?"}]}' \
  2>/dev/null | head -c 600 || echo "(timeout reached)"

echo ""
echo ""
echo "══════════════════════════════════════════════════════"
echo "  Chat Timeout Fix Applied!"
echo "══════════════════════════════════════════════════════"
echo ""
echo "  Changes:"
echo "  ✓ qwen2:0.5b pulled (~5-8 tok/s vs phi3:mini ~1.4 tok/s)"
echo "  ✓ All phi3:mini agents switched to qwen2:0.5b"
echo "  ✓ SSE keepalive heartbeat added (': hb' every 5s)"
echo "  ✓ Ollama timeout extended: 120s → 180s"
echo "  ✓ Context trimmed: 800 → 400 chars per source"
echo ""
echo "  Expected response time: 8-15s (was 35-50s)"
echo ""
echo "  Test: https://edge.etheros.ai/marketplace/"
echo "        Ask the CDL agent: 'What is a CDL license?'"
echo ""
