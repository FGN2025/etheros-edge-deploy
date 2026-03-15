#!/usr/bin/env bash
# Pull lightweight fast models for low-latency chat on CPU
echo "══════════════════════════════════════════════════"
echo "  EtherOS — Pull Fast CPU Models                  "
echo "══════════════════════════════════════════════════"
echo ""
echo "▸ Pulling qwen2:0.5b (~350 MB, ~5-8 tok/s on CPU)..."
docker exec etheros-ollama ollama pull qwen2:0.5b
echo "  ✓ qwen2:0.5b ready"
echo ""
echo "▸ Pulling tinyllama (~637 MB, ~4-6 tok/s on CPU)..."
docker exec etheros-ollama ollama pull tinyllama
echo "  ✓ tinyllama ready"
echo ""
echo "▸ Available models:"
docker exec etheros-ollama ollama list
echo ""
echo "══════════════════════════════════════════════════"
echo "  Fast models available in Agent Builder!         "
echo "══════════════════════════════════════════════════"
