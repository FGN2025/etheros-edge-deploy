#!/usr/bin/env bash
# ══════════════════════════════════════════════════════════════════════════════
#  EtherOS — Fix CDL Agent via Live API + Force agents.json Write
#
#  The loadAgents() wrapper in server.js is not picking up agents.json.
#  Root cause: the seed array patch from previous scripts broke the wrapping.
#
#  This script takes a different approach:
#  1. PATCH the CDL agent live via API (fixes in memory immediately)
#  2. PATCH all phi3:mini agents to qwen2:0.5b via API
#  3. Trigger a saveAgents() by doing a no-op PATCH on each agent
#     → this writes the correct agents.json to disk so restarts work
#  4. Verify the fix persisted to disk
#
#  Run as: bash <(curl -fsSL https://raw.githubusercontent.com/FGN2025/etheros-edge-deploy/main/fix-cdl-via-api.sh)
# ══════════════════════════════════════════════════════════════════════════════

echo ""
echo "══════════════════════════════════════════════════════"
echo "  EtherOS — Fix CDL Agent + Persist to Disk"
echo "══════════════════════════════════════════════════════"
echo ""

API="http://localhost:3011"

echo "▸ Step 1: Patching CDL agent (model + connector) via live API..."
RESULT=$(curl -s -X PATCH "$API/api/agents/1350abe4" \
  -H "Content-Type: application/json" \
  -d '{
    "modelId": "qwen2:0.5b",
    "notebookConnectorIds": ["nb-240ad8b4"]
  }')
echo "  Response: $RESULT" | head -c 200
echo ""

# Check it worked
MODEL=$(echo "$RESULT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('modelId','?'))" 2>/dev/null)
CONN=$(echo "$RESULT"  | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('notebookConnectorIds','?'))" 2>/dev/null)
echo "  model=$MODEL  connectors=$CONN"

if [ "$MODEL" = "qwen2:0.5b" ]; then
  echo "  ✓ CDL model patched to qwen2:0.5b"
else
  echo "  ✗ Model patch failed (got: $MODEL)"
fi

if echo "$CONN" | grep -q "nb-240ad8b4"; then
  echo "  ✓ CDL connector patched to nb-240ad8b4"
else
  echo "  ✗ Connector patch failed (got: $CONN)"
fi
echo ""

echo "▸ Step 2: Switching all phi3:mini agents to qwen2:0.5b..."
# Get all agents and patch the ones with phi3:mini
curl -s "$API/api/agents" | python3 -c "
import sys, json, subprocess

agents = json.load(sys.stdin)
for a in agents:
    if a.get('modelId') == 'phi3:mini':
        agent_id = a['id']
        result = subprocess.run(
            ['curl', '-s', '-X', 'PATCH', f'http://localhost:3011/api/agents/{agent_id}',
             '-H', 'Content-Type: application/json',
             '-d', '{\"modelId\": \"qwen2:0.5b\"}'],
            capture_output=True, text=True
        )
        try:
            updated = json.loads(result.stdout)
            new_model = updated.get('modelId', '?')
            print(f'  ✓ {agent_id[:8]} ({a[\"slug\"]}) → {new_model}')
        except:
            print(f'  ✗ {agent_id[:8]} ({a[\"slug\"]}) patch failed: {result.stdout[:80]}')
    else:
        print(f'  - {a[\"id\"][:8]} ({a[\"slug\"]}) already {a[\"modelId\"]} — skip')
"
echo ""

echo "▸ Step 3: Verifying agents in memory..."
curl -s "$API/api/agents" | python3 -c "
import sys, json
agents = json.load(sys.stdin)
print(f'  Total: {len(agents)} agents')
all_ok = True
for a in agents:
    cids = a.get('notebookConnectorIds', [])
    bad_conn = 'nb-cc2657f1' in cids
    bad_model = a.get('modelId') == 'phi3:mini'
    flag = '✗' if (bad_conn or bad_model) else '✓'
    if bad_conn or bad_model: all_ok = False
    print(f'  {flag} {a[\"id\"][:8]:8} {a[\"slug\"]:32} model={a[\"modelId\"]:12} conn={cids}')
print()
print('  ' + ('✓ All agents correct' if all_ok else '✗ Some agents still wrong'))
"
echo ""

echo "▸ Step 4: Checking agents.json was written to disk by saveAgents()..."
sleep 1
DATA_FILE="/opt/etheros-edge/data/agents.json"
if [ -f "$DATA_FILE" ]; then
  SIZE=$(wc -c < "$DATA_FILE")
  echo "  ✓ $DATA_FILE exists ($SIZE bytes)"
  # Verify CDL is correct in the file
  python3 -c "
import json
with open('$DATA_FILE') as f:
    agents = json.load(f)
cdl = next((a for a in agents if a['id'] == '1350abe4'), None)
if cdl:
    ok_m = cdl['modelId'] == 'qwen2:0.5b'
    ok_c = cdl.get('notebookConnectorIds') == ['nb-240ad8b4']
    print(f'  CDL on disk: model={cdl[\"modelId\"]} connectors={cdl.get(\"notebookConnectorIds\")}')
    print(f'  {\"✓\" if ok_m else \"✗\"} model  {\"✓\" if ok_c else \"✗\"} connector')
else:
    print('  ⚠  CDL agent not found in disk file')
"
else
  echo "  ✗ agents.json not written — saveAgents() may not be wired to PATCH"
  echo "  Forcing write via Python..."
  python3 -c "
import json, subprocess, os

# Fetch current agents from backend
result = subprocess.run(['curl','-s','http://localhost:3011/api/agents'],
    capture_output=True, text=True)
agents = json.loads(result.stdout)

os.makedirs('/opt/etheros-edge/data', exist_ok=True)
with open('/opt/etheros-edge/data/agents.json','w') as f:
    json.dump(agents, f, indent=2)
print(f'  ✓ Wrote {len(agents)} agents to disk manually')
for a in agents:
    cids = a.get('notebookConnectorIds',[])
    print(f'  - {a[\"id\"][:8]} {a[\"slug\"]:32} {a[\"modelId\"]:12} {cids}')
"
fi

echo ""
echo "▸ Step 5: Quick stream test (direct on port 3011)..."
timeout 20 curl -s -N \
  -X POST "$API/api/agents/1350abe4/chat/stream" \
  -H "Content-Type: application/json" \
  -d '{"messages":[{"role":"user","content":"What is a CDL in one sentence?"}]}' \
  2>/dev/null | head -c 500
echo ""
echo ""

echo "══════════════════════════════════════════════════════"
echo "  CDL Agent Fix Complete"
echo "══════════════════════════════════════════════════════"
echo ""
echo "  Test: https://edge.etheros.ai/marketplace/"
echo "  Ask: 'What is a CDL license?'"
echo ""
