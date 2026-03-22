#!/bin/bash
# Sprint 4AA — Markdown rendering in chat + concise response prompts
# 1. Hot-swap JS bundle (markdown renderer)
# 2. Update agent system prompts in live DB to encourage concise responses
# 3. Redeploy agents.js with updated prompts + Sprint 4Z model fix

set -e
STATIC="/opt/etheros-edge/static/isp-portal"
REPO="https://raw.githubusercontent.com/FGN2025/etheros-edge-deploy/main"
CONTAINER="etheros-isp-portal-backend"

echo "=== Sprint 4AA: Markdown rendering + concise response prompts ==="

echo "[1/4] Pulling new JS bundle (markdown renderer)..."
curl -fsSL -o "$STATIC/assets/index-BknN6bAR.js" "$REPO/static/isp-portal/assets/index-BknN6bAR.js"
echo "      index-BknN6bAR.js deployed"

echo "[2/4] Removing old bundle..."
rm -f "$STATIC/assets/index-B6xlMmxY.js"
rm -f "$STATIC/assets/index-DLBe0prN.js"
echo "      Old bundles removed"

echo "[3/4] Updating index.html..."
curl -fsSL -o "$STATIC/index.html" "$REPO/static/isp-portal/index.html"
echo "      index.html updated"

echo "[4/4] Updating agents.js + patching live DB system prompts..."
curl -fsSL -o /tmp/agents.js "$REPO/backends/isp-portal/routes/agents.js"
docker cp /tmp/agents.js $CONTAINER:/app/routes/agents.js

# Patch live DB — append formatting hint to system prompts that don't have it
docker exec $CONTAINER node -e "
const { getDb } = require('./db');
const db = getDb(process.env.DATA_DIR || '/app/data');
const hint = ' Respond concisely. Use short paragraphs or bullet points. Avoid long run-on responses.';
const agents = db.prepare('SELECT id, system_prompt FROM agents').all();
let updated = 0;
for (const a of agents) {
  if (!a.system_prompt.includes('Respond concisely')) {
    db.prepare('UPDATE agents SET system_prompt=? WHERE id=?').run(a.system_prompt + hint, a.id);
    updated++;
  }
}
console.log('System prompts updated:', updated);
"

docker restart $CONTAINER
echo "      Backend restarted"

echo ""
echo "=== Done! Chat now renders **bold**, bullets, and paragraphs properly ==="
echo "All agents now respond with concise, structured formatting."
