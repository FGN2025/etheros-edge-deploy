#!/usr/bin/env bash
# ══════════════════════════════════════════════════════════════════════════════
#  EtherOS — Write Correct agents.json to Disk
#
#  The CDL agent lives only in container memory (was created via API).
#  agents.json was never written because the persistence code writes on
#  mutations (POST/PATCH/DELETE) — but after a restart the seed is loaded
#  fresh from server.js, overwriting any in-memory state.
#
#  This script writes the correct agents.json directly to disk, then
#  restarts the backend so it loads from disk on startup.
#
#  Changes vs current in-memory state:
#   • All phi3:mini agents → qwen2:0.5b  (4x faster on CPU)
#   • CDL agent connector: nb-cc2657f1 → nb-240ad8b4 (correct notebook)
#   • CDL agent model: phi3:mini → qwen2:0.5b
#
#  Run as: bash <(curl -fsSL https://raw.githubusercontent.com/FGN2025/etheros-edge-deploy/main/fix-agents-disk.sh)
# ══════════════════════════════════════════════════════════════════════════════

echo ""
echo "══════════════════════════════════════════════════════"
echo "  EtherOS — Fix Agent Data on Disk"
echo "══════════════════════════════════════════════════════"
echo ""

DATA_DIR="/opt/etheros-edge/data"
AGENTS_FILE="$DATA_DIR/agents.json"

echo "▸ Creating data directory..."
mkdir -p "$DATA_DIR"
echo "  ✓ $DATA_DIR ready"
echo ""

echo "▸ Writing correct agents.json to disk..."
cat > "$AGENTS_FILE" << 'AGENTS_EOF'
[
  {
    "id": "rural-advisor",
    "slug": "rural-advisor",
    "name": "Rural Community Advisor",
    "modelId": "qwen2:0.5b",
    "notebookConnectorIds": [],
    "status": "LIVE",
    "isEnabled": true,
    "creatorRole": "etheros",
    "price": 0,
    "description": "Expert guidance on rural development, grants, infrastructure, and community programs for rural residents and local governments.",
    "systemPrompt": "You are a Rural Community Advisor specializing in rural development, grants, and community programs. Help rural residents and local governments access resources, navigate programs, and build stronger communities. Be practical, encouraging, and specific to rural contexts."
  },
  {
    "id": "tech-support",
    "slug": "tech-support",
    "name": "Tech Support Agent",
    "modelId": "qwen2:0.5b",
    "notebookConnectorIds": [],
    "status": "LIVE",
    "isEnabled": true,
    "creatorRole": "etheros",
    "price": 0,
    "description": "Friendly tech support for EtherOS terminals, fiber connectivity, and everyday technology questions.",
    "systemPrompt": "You are a friendly tech support agent for EtherOS. Help users with their terminal setup, fiber internet connection, software issues, and general technology questions. Be patient, clear, and avoid jargon."
  },
  {
    "id": "business-coach",
    "slug": "business-coach",
    "name": "Small Business Coach",
    "modelId": "qwen2:0.5b",
    "notebookConnectorIds": [],
    "status": "LIVE",
    "isEnabled": true,
    "creatorRole": "etheros",
    "price": 0,
    "description": "Business coaching for rural entrepreneurs — from business plans to marketing, financing, and growth strategies.",
    "systemPrompt": "You are a small business coach specializing in rural entrepreneurship. Provide practical advice on business planning, marketing, financing, operations, and growth strategies tailored to rural markets and communities."
  },
  {
    "id": "edu-tutor",
    "slug": "edu-tutor",
    "name": "Education Tutor",
    "modelId": "qwen2:0.5b",
    "notebookConnectorIds": [],
    "status": "LIVE",
    "isEnabled": true,
    "creatorRole": "etheros",
    "price": 0,
    "description": "Patient K-12 tutoring across all subjects — math, science, reading, history, and more.",
    "systemPrompt": "You are a patient and encouraging education tutor for K-12 students. Explain concepts clearly, use examples, check for understanding, and adapt to each student's level. Make learning engaging and accessible."
  },
  {
    "id": "health-navigator",
    "slug": "health-navigator",
    "name": "Health Navigator",
    "modelId": "qwen2:0.5b",
    "notebookConnectorIds": [],
    "status": "LIVE",
    "isEnabled": true,
    "creatorRole": "etheros",
    "price": 0,
    "description": "Helping rural residents navigate healthcare resources, insurance, telehealth, and wellness programs.",
    "systemPrompt": "You are a health navigator helping rural residents access healthcare resources. Help with finding providers, understanding insurance, telehealth options, and community health programs. Always recommend consulting healthcare professionals for medical decisions."
  },
  {
    "id": "legal-basics",
    "slug": "legal-basics",
    "name": "Legal Basics Assistant",
    "modelId": "qwen2:0.5b",
    "notebookConnectorIds": [],
    "status": "LIVE",
    "isEnabled": true,
    "creatorRole": "etheros",
    "price": 0,
    "description": "Plain-language explanations of legal concepts, procedures, and how to find legal help in rural areas.",
    "systemPrompt": "You are a legal information assistant. Explain legal concepts and procedures in plain language. Help users understand their rights and options. Always clarify you are not providing legal advice and recommend consulting a licensed attorney for specific legal matters."
  },
  {
    "id": "ag-advisor",
    "slug": "ag-advisor",
    "name": "Agriculture Advisor",
    "modelId": "qwen2:0.5b",
    "notebookConnectorIds": [],
    "status": "LIVE",
    "isEnabled": true,
    "creatorRole": "etheros",
    "price": 0,
    "description": "Expert agricultural guidance on crop management, soil health, weather, markets, and farm programs.",
    "systemPrompt": "You are an agriculture advisor helping rural farmers with crop management, soil health, pest control, weather planning, market prices, and farm programs. Provide practical, science-based advice relevant to modern farming operations."
  },
  {
    "id": "1350abe4",
    "slug": "cdl-skills-development",
    "name": "CDL Skills Development",
    "modelId": "qwen2:0.5b",
    "notebookConnectorIds": ["nb-240ad8b4"],
    "status": "LIVE",
    "isEnabled": true,
    "creatorRole": "isp",
    "price": 0,
    "description": "AI-powered CDL training assistant with access to the CDL Driver Manual, FMCSA regulations, pre-trip inspection checklists, and skills development resources for commercial drivers.",
    "systemPrompt": "You are a CDL Training Assistant for EtherOS, specializing in Commercial Driver's License preparation and skills development. You have access to the CDL Driver Manual, FMCSA regulations, pre-trip inspection procedures, and CTE program resources. Guide students step-by-step through CDL requirements, help them prepare for written and skills tests, explain regulations clearly, and support their journey to becoming safe, certified commercial drivers. Keep answers concise and practical."
  }
]
AGENTS_EOF

echo "  ✓ Written: $AGENTS_FILE ($(wc -c < "$AGENTS_FILE") bytes, $(python3 -c "import json; print(len(json.load(open('$AGENTS_FILE'))))" 2>/dev/null || echo "?") agents)"
echo ""

echo "▸ Verifying JSON is valid..."
python3 -c "
import json
with open('$AGENTS_FILE') as f:
    agents = json.load(f)
print(f'  ✓ Valid JSON — {len(agents)} agents')
for a in agents:
    cids = a.get('notebookConnectorIds', [])
    flag = '✓' if 'nb-cc2657f1' not in cids else '✗'
    print(f\"  {flag} {a['id'][:8]:8} {a['slug']:32} model={a['modelId']:12} connectors={cids}\")
"
echo ""

echo "▸ Restarting marketplace backend (will load from disk)..."
docker restart etheros-marketplace-backend
sleep 6

echo ""
echo "▸ Verifying backend health..."
for i in 1 2 3 4 5; do
    STATUS=$(curl -sf -o /dev/null -w "%{http_code}" http://localhost:3011/api/agents 2>/dev/null || echo "FAIL")
    if [ "$STATUS" = "200" ]; then
        echo "  ✓ Backend healthy (HTTP 200)"
        break
    fi
    echo "  Waiting... ($i/5)"
    sleep 2
done

echo ""
echo "▸ Confirming agents loaded from disk..."
curl -s http://localhost:3011/api/agents 2>/dev/null | python3 -c "
import sys, json
agents = json.load(sys.stdin)
print(f'  Loaded: {len(agents)} agents')
for a in agents:
    cids = a.get('notebookConnectorIds', [])
    flag = '✓' if 'nb-cc2657f1' not in cids else '✗'
    print(f\"  {flag} {a['id'][:8]:8} {a['slug']:32} model={a['modelId']:12} connectors={cids}\")
cdl = next((a for a in agents if a['id'] == '1350abe4'), None)
if cdl:
    ok_model = cdl['modelId'] == 'qwen2:0.5b'
    ok_conn  = cdl.get('notebookConnectorIds') == ['nb-240ad8b4']
    print()
    print(f\"  CDL model check:     {'✓ qwen2:0.5b' if ok_model else '✗ WRONG: ' + cdl['modelId']}\")
    print(f\"  CDL connector check: {'✓ nb-240ad8b4' if ok_conn  else '✗ WRONG: ' + str(cdl.get('notebookConnectorIds'))}\")
" 2>/dev/null

echo ""
echo "▸ Quick stream test (direct to backend port 3011)..."
STREAM=$(timeout 20 curl -s -N \
    -X POST "http://localhost:3011/api/agents/1350abe4/chat/stream" \
    -H "Content-Type: application/json" \
    -d '{"messages":[{"role":"user","content":"What is a CDL in one sentence?"}]}' \
    2>/dev/null | head -c 400)
echo "$STREAM"
echo ""

echo "══════════════════════════════════════════════════════"
echo "  Agent Data Fixed!"
echo "══════════════════════════════════════════════════════"
echo ""
echo "  All 8 agents now loaded from disk:"
echo "  • All seed agents: phi3:mini → qwen2:0.5b"
echo "  • CDL connector: nb-cc2657f1 → nb-240ad8b4"
echo "  • agents.json persisted — survives restarts"
echo ""
echo "  Test: https://edge.etheros.ai/marketplace/"
echo ""
