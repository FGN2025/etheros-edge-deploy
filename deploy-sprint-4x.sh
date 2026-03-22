#!/bin/bash
# Sprint 4X — Update all agent models to llama3.2:3b
# 1. Hot-swap agents.js in the running container
# 2. Run SQLite UPDATE to patch existing DB records
# 3. Restart backend to pick up new defaults

set -e
REPO="https://raw.githubusercontent.com/FGN2025/etheros-edge-deploy/main"
CONTAINER="etheros-isp-portal-backend"

echo "=== Sprint 4X: Update agent models to llama3.2:3b ==="

# Step 1 — pull updated agents.js into container
echo "[1/3] Pulling updated agents.js..."
curl -fsSL -o /tmp/agents.js "$REPO/backends/isp-portal/routes/agents.js"
docker cp /tmp/agents.js $CONTAINER:/app/routes/agents.js
echo "      agents.js deployed"

# Step 2 — patch existing SQLite DB records (DB lives inside the container volume)
echo "[2/3] Patching live SQLite DB — setting all agents to llama3.2:3b..."
docker exec $CONTAINER node -e "
const { getDb } = require('./db');
const db = getDb(process.env.DATA_DIR || '/app/data');
const result = db.prepare(\"UPDATE agents SET model_id='llama3.2:3b' WHERE model_id='llama3.1:8b'\").run();
console.log('Rows updated:', result.changes);
"
echo "      DB patched"

# Step 3 — restart backend
echo "[3/3] Restarting backend..."
docker restart $CONTAINER
echo "      Backend restarted"

echo ""
echo "=== Done! All agents now use llama3.2:3b ==="
echo "Verify: curl -s https://edge.etheros.ai/isp-portal/api/agents | python3 -m json.tool | grep model_id"
