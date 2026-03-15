#!/usr/bin/env bash
# Adds PATCH /api/settings directly into server.js and restarts
set -e
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
SERVER="/opt/etheros-edge/backends/isp-portal/server.js"

echo -e "${YELLOW}▸${NC} Patching server.js..."

python3 << 'PYEOF'
content = open('/opt/etheros-edge/backends/isp-portal/server.js').read()

patch = """
// ── PATCH /api/settings ───────────────────────────────────────────────────────
app.patch('/api/settings', (req, res) => {
  const existing = loadSettings();
  const update = { ...existing, ...req.body };
  if ((update.stripeKey || '').includes('\u2022\u2022\u2022\u2022')) {
    update.stripeKey = existing.stripeKey;
  }
  saveSettings(update);
  res.json({ ok: true });
});
"""

if "app.patch('/api/settings'" not in content:
    # Insert before the stripe-key-test endpoint
    marker = "// \u2500\u2500 GET /api/settings/stripe-key-test"
    if marker in content:
        content = content.replace(marker, patch + '\n' + marker)
    else:
        # Fallback: insert before health endpoint
        content = content.replace("// \u2500\u2500 Health", patch + '\n// \u2500\u2500 Health')
    open('/opt/etheros-edge/backends/isp-portal/server.js', 'w').write(content)
    print("PATCH route added")
else:
    print("Already exists")
PYEOF

echo -e "${YELLOW}▸${NC} Restarting..."
docker restart etheros-isp-portal-backend
sleep 3

echo -e "${YELLOW}▸${NC} Testing..."
RESULT=$(curl -s -X PATCH http://127.0.0.1:3010/api/settings \
  -H "Content-Type: application/json" \
  -d '{"_test":true}')
echo "Result: $RESULT"
echo -e "${GREEN}✓${NC} Done"
