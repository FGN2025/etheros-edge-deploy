#!/usr/bin/env bash
set -e
EDGE_DIR="/opt/etheros-edge"
MKT_SERVER="$EDGE_DIR/backends/marketplace/server.js"
DATA_DIR="$EDGE_DIR/data"

echo "══════════════════════════════════════════════════"
echo "  EtherOS — Agent Persistence Fix                 "
echo "══════════════════════════════════════════════════"
echo ""

echo "▸ Creating data directory for persistent storage..."
mkdir -p "$DATA_DIR"
echo "  ✓ $DATA_DIR ready"

echo "▸ Backing up current marketplace server.js..."
cp "$MKT_SERVER" "${MKT_SERVER}.bak.$(date +%s)"
echo "  ✓ Backed up"

echo "▸ Patching server.js for disk persistence..."
python3 << 'PYEOF'
import re

with open('/opt/etheros-edge/backends/marketplace/server.js', 'r') as f:
    src = f.read()

# ── 1. Add fs/path requires at the top ────────────────────────────────────────
old_requires = "'use strict';\nconst express = require('express');\nconst cors = require('cors');\nconst { randomUUID } = require('crypto');"

new_requires = """'use strict';
const express = require('express');
const cors = require('cors');
const { randomUUID } = require('crypto');
const fs = require('fs');
const path = require('path');

// ── Persistent storage helpers ─────────────────────────────────────────────────
const DATA_DIR = '/opt/etheros-edge/data';
const AGENTS_FILE = path.join(DATA_DIR, 'agents.json');

function loadAgents(seedAgents) {
  try {
    if (fs.existsSync(AGENTS_FILE)) {
      const saved = JSON.parse(fs.readFileSync(AGENTS_FILE, 'utf8'));
      if (Array.isArray(saved) && saved.length > 0) {
        console.log(`[persistence] Loaded ${saved.length} agents from disk`);
        return saved;
      }
    }
  } catch (err) {
    console.error('[persistence] Failed to load agents from disk:', err.message);
  }
  console.log(`[persistence] Using seed agents (${seedAgents.length})`);
  saveAgents(seedAgents);
  return seedAgents;
}

function saveAgents(agents) {
  try {
    fs.mkdirSync(DATA_DIR, { recursive: true });
    fs.writeFileSync(AGENTS_FILE, JSON.stringify(agents, null, 2));
  } catch (err) {
    console.error('[persistence] Failed to save agents to disk:', err.message);
  }
}"""

src = src.replace(old_requires, new_requires)

# ── 2. Replace db.agents array initialisation with loadAgents() call ──────────
# Find the seed agents array and wrap it
import re

# Replace:  agents: [ ... seed data ... ],
# With:     agents: loadAgents([ ... seed data ... ]),
src = re.sub(
    r'(const db = \{[\s\S]*?agents:\s*)(\[[\s\S]*?\]),(\s*ispTenants:)',
    r'\1loadAgents(\2),\3',
    src,
    count=1
)

# ── 3. After every mutating agents operation, call saveAgents ─────────────────
# POST /api/agents — after push
src = src.replace(
    'db.agents.push(agent);\n  res.status(201).json(agent);',
    'db.agents.push(agent);\n  saveAgents(db.agents);\n  res.status(201).json(agent);'
)

# PATCH /api/agents/:id — after Object.assign
src = src.replace(
    'Object.assign(a, req.body);\n  res.json(a);',
    'Object.assign(a, req.body);\n  saveAgents(db.agents);\n  res.json(a);'
)

# DELETE /api/agents/:id — after splice
src = src.replace(
    'db.agents.splice(idx, 1);\n  res.json({ success: true });',
    'db.agents.splice(idx, 1);\n  saveAgents(db.agents);\n  res.json({ success: true });'
)

with open('/opt/etheros-edge/backends/marketplace/server.js', 'w') as f:
    f.write(src)

print("  ✓ Persistence patches applied")
PYEOF

echo "▸ Restarting marketplace backend..."
docker restart etheros-marketplace-backend
sleep 4

echo "▸ Verifying backend is healthy..."
for i in 1 2 3 4 5; do
  STATUS=$(curl -sf -o /dev/null -w "%{http_code}" http://localhost:3011/api/agents 2>/dev/null || echo "FAIL")
  if [ "$STATUS" = "200" ]; then
    echo "  ✓ Backend responding (HTTP 200)"
    break
  fi
  echo "  Waiting... ($i/5)"
  sleep 2
done

echo "▸ Checking agent count..."
COUNT=$(curl -s http://localhost:3011/api/agents | python3 -c "import sys,json; print(len(json.load(sys.stdin)))" 2>/dev/null || echo "?")
echo "  ✓ $COUNT agents in store"

echo "▸ Checking agents.json on disk..."
if [ -f "$DATA_DIR/agents.json" ]; then
  echo "  ✓ $DATA_DIR/agents.json exists ($(wc -c < "$DATA_DIR/agents.json") bytes)"
else
  echo "  ⚠ agents.json not yet created (will be created on first write)"
fi

echo ""
echo "══════════════════════════════════════════════════"
echo "  Agent persistence fix applied!                  "
echo "══════════════════════════════════════════════════"
echo ""
echo "  Agents are now saved to: $DATA_DIR/agents.json"
echo "  Restarts will no longer lose agent data."
echo ""
echo "  Next: Re-create the CDL Training agent via"
echo "  Super Admin → New Agent (it was lost on restart)"
