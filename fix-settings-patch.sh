#!/usr/bin/env bash
# fix-settings-patch.sh — adds PATCH /api/settings alias and fixes Settings page routing
set -e
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
SERVER="/opt/etheros-edge/backends/isp-portal/server.js"

echo -e "${YELLOW}▸${NC} Adding PATCH /api/settings alias..."

# Add PATCH alias right after the POST /api/settings block
python3 << PYEOF
content = open('$SERVER').read()

patch_route = """
// ── PATCH /api/settings (alias for POST — frontend uses PATCH) ────────────────
app.patch('/api/settings', (req, res) => {
  const existing = loadSettings();
  const update = { ...existing, ...req.body };
  if ((update.stripeKey || '').includes('••••••••')) {
    update.stripeKey = existing.stripeKey;
  }
  saveSettings(update);
  res.json({ ok: true });
});
"""

# Insert after POST /api/settings block
marker = "// ── GET/POST /api/settings"
if "app.patch('/api/settings'" not in content:
    # Find end of POST settings handler and insert after
    insert_after = "// ── GET /api/settings/stripe-key-test"
    content = content.replace(insert_after, patch_route + "\n" + insert_after)
    open('$SERVER', 'w').write(content)
    print("PATCH route added")
else:
    print("PATCH route already exists — skipping")
PYEOF

echo -e "  ${GREEN}✓${NC} PATCH route added"

echo -e "${YELLOW}▸${NC} Restarting backend..."
docker restart etheros-isp-portal-backend
sleep 2

echo -e "${YELLOW}▸${NC} Testing PATCH endpoint..."
RESULT=$(curl -s -X PATCH http://127.0.0.1:3010/api/settings \
  -H "Content-Type: application/json" \
  -d '{"_test":true}' | python3 -c "import sys,json; print(json.load(sys.stdin).get('ok','FAIL'))")
echo -e "  PATCH /api/settings → $RESULT"

echo -e "${GREEN}✓${NC} Done — Settings page should work now"
