#!/bin/bash
# Sprint 4AA — Markdown rendering in chat + concise response prompts
# 1. Hot-swap JS bundle (markdown renderer)
# 2. Hot-swap CSS bundle (hash changed)
# 3. Update agent system prompts in live DB to encourage concise responses
# 4. Redeploy agents.js

set -e
STATIC="/opt/etheros-edge/static/isp-portal"
REPO="https://raw.githubusercontent.com/FGN2025/etheros-edge-deploy/main"
CONTAINER="etheros-isp-portal-backend"

echo "=== Sprint 4AA: Markdown rendering + concise response prompts ==="

echo "[1/5] Pulling new JS bundle (markdown renderer)..."
curl -fsSL -o "$STATIC/assets/index-BknN6bAR.js" "$REPO/static/isp-portal/assets/index-BknN6bAR.js"
echo "      index-BknN6bAR.js deployed"

echo "[2/5] Pulling new CSS bundle..."
curl -fsSL -o "$STATIC/assets/index-Ap3k7dPu.css" "$REPO/static/isp-portal/assets/index-Ap3k7dPu.css"
echo "      index-Ap3k7dPu.css deployed"

echo "[3/5] Removing old bundles..."
rm -f "$STATIC/assets/index-B6xlMmxY.js"
rm -f "$STATIC/assets/index-DLBe0prN.js"
rm -f "$STATIC/assets/index-CmP-1APZ.css"
echo "      Old bundles removed"

echo "[4/5] Updating index.html..."
curl -fsSL -o "$STATIC/index.html" "$REPO/static/isp-portal/index.html"
echo "      index.html updated"

echo "[5/5] Updating agents.js + patching live DB system prompts..."
curl -fsSL -o /tmp/agents.js "$REPO/backends/isp-portal/routes/agents.js"
docker cp /tmp/agents.js $CONTAINER:/app/routes/agents.js

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
