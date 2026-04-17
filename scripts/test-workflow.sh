#!/bin/bash
# Post-reboot workflow test for OpenClaw on Jetson
# Run from Mac: ./scripts/test-workflow.sh
set -euo pipefail

JETSON="akshay@10.0.0.7"
PASS=0
FAIL=0
WARN=0

green() { printf "\033[32m✓ %s\033[0m\n" "$1"; PASS=$((PASS+1)); }
red()   { printf "\033[31m✗ %s\033[0m\n" "$1"; FAIL=$((FAIL+1)); }
yellow(){ printf "\033[33m⚠ %s\033[0m\n" "$1"; WARN=$((WARN+1)); }

echo "=== OpenClaw Post-Reboot Workflow Test ==="
echo ""

# 1. SSH connectivity
echo "--- Connectivity ---"
if ssh -o ConnectTimeout=5 $JETSON "echo ok" >/dev/null 2>&1; then
  green "SSH to Jetson"
else
  red "SSH to Jetson (is it back up?)"
  echo "Aborting. Jetson not reachable."
  exit 1
fi

# 2. Ollama
echo ""
echo "--- Ollama ---"
OLLAMA_STATUS=$(ssh $JETSON "systemctl is-active ollama 2>/dev/null" 2>/dev/null || echo "inactive")
if [ "$OLLAMA_STATUS" = "active" ]; then
  green "Ollama service running"
else
  red "Ollama service not running (status: $OLLAMA_STATUS)"
fi

OLLAMA_MODELS=$(ssh $JETSON "curl -s http://localhost:11434/api/tags 2>/dev/null" 2>/dev/null || echo "{}")
if echo "$OLLAMA_MODELS" | grep -q "qwen2.5:3b"; then
  green "qwen2.5:3b model available"
else
  red "qwen2.5:3b model not found in ollama"
fi

# 3. Ollama inference test
OLLAMA_RESP=$(ssh $JETSON 'curl -s http://localhost:11434/api/chat -d "{\"model\":\"qwen2.5:3b\",\"stream\":false,\"messages\":[{\"role\":\"user\",\"content\":\"Say hello in exactly 3 words\"}]}" 2>/dev/null' 2>/dev/null || echo "")
if echo "$OLLAMA_RESP" | grep -q '"content"'; then
  green "qwen2.5:3b inference working"
else
  red "qwen2.5:3b inference failed"
fi

# 4. OpenClaw gateway
echo ""
echo "--- OpenClaw Gateway ---"
GW_STATUS=$(ssh $JETSON "systemctl --user is-active openclaw-gateway 2>/dev/null" 2>/dev/null || echo "inactive")
if [ "$GW_STATUS" = "active" ]; then
  green "OpenClaw gateway running"
else
  red "OpenClaw gateway not running (status: $GW_STATUS)"
fi

GW_LOG=$(ssh $JETSON "grep -c 'ready' /tmp/openclaw/openclaw-$(date +%Y-%m-%d).log 2>/dev/null" 2>/dev/null || echo "0")
if [ "$GW_LOG" -gt 0 ]; then
  green "Gateway logged 'ready' today"
else
  yellow "No 'ready' in today's log (may still be starting)"
fi

# 5. LM Studio on Mac
echo ""
echo "--- LM Studio (Mac) ---"
MAC_MODELS=$(curl -s http://10.0.0.131:1234/v1/models 2>/dev/null || echo "")
if echo "$MAC_MODELS" | grep -q "gemma"; then
  green "LM Studio reachable, gemma-4 loaded"
else
  red "LM Studio not reachable or gemma-4 not loaded"
fi

# 6. Telegram channel
echo ""
echo "--- Telegram ---"
TG_LOG=$(ssh $JETSON "grep -c 'starting provider' /tmp/openclaw/openclaw-$(date +%Y-%m-%d).log 2>/dev/null" 2>/dev/null || echo "0")
if [ "$TG_LOG" -gt 0 ]; then
  green "Telegram provider started"
else
  yellow "Telegram provider not confirmed in logs yet"
fi

# 7. Hooks API
echo ""
echo "--- Hooks API ---"
HOOKS_TOKEN=$(ssh $JETSON "python3 -c \"import json; c=json.load(open('/home/akshay/.openclaw/openclaw.json')); print(c.get('hooks',{}).get('token',''))\"" 2>/dev/null)
if [ -n "$HOOKS_TOKEN" ]; then
  HOOK_RESP=$(ssh $JETSON "curl -s -o /dev/null -w '%{http_code}' -X POST -H 'Authorization: Bearer $HOOKS_TOKEN' -H 'Content-Type: application/json' http://127.0.0.1:18789/hooks/wake -d '{\"text\":\"post-reboot test\",\"mode\":\"queue\"}'" 2>/dev/null || echo "000")
  if [ "$HOOK_RESP" = "200" ]; then
    green "Hooks API responding (POST /hooks/wake returned 200)"
  else
    red "Hooks API not responding (HTTP $HOOK_RESP)"
  fi
else
  red "Could not read hooks token from config"
fi

# 8. gog CLI / Gmail auth
echo ""
echo "--- Gmail (gog CLI) ---"
GOG_CHECK=$(ssh $JETSON "export PATH=\$PATH:/home/akshay/.local/bin && gog gmail messages list 'is:unread' --max 1 --json -a akshayadavadditional@gmail.com 2>&1" 2>/dev/null || echo "error")
if echo "$GOG_CHECK" | grep -q '"messages"'; then
  green "gog CLI authenticated, Gmail accessible"
elif echo "$GOG_CHECK" | grep -qi "auth\|token\|expired\|invalid"; then
  red "gog auth expired or invalid (re-auth needed from Mac)"
else
  yellow "gog returned unexpected output: $(echo "$GOG_CHECK" | head -1)"
fi

# 9. Cron
echo ""
echo "--- Cron ---"
CRON_CHECK=$(ssh $JETSON "crontab -l 2>/dev/null | grep gmail-poll" 2>/dev/null || echo "")
if [ -n "$CRON_CHECK" ]; then
  green "Gmail poll cron job installed"
else
  red "Gmail poll cron job missing"
fi

# 10. End-to-end: trigger Comms agent
echo ""
echo "--- End-to-End: Comms Agent via Hooks ---"
if [ -n "$HOOKS_TOKEN" ]; then
  E2E_RESP=$(ssh $JETSON "curl -s -X POST -H 'Authorization: Bearer $HOOKS_TOKEN' -H 'Content-Type: application/json' http://127.0.0.1:18789/hooks/agent -d '{\"agentId\":\"comms\",\"message\":\"Respond with exactly: COMMS_TEST_OK\",\"name\":\"reboot-test\",\"wakeMode\":\"now\"}'" 2>/dev/null || echo "")
  if echo "$E2E_RESP" | grep -q '"ok":true'; then
    RUN_ID=$(echo "$E2E_RESP" | python3 -c "import sys,json; print(json.load(sys.stdin).get('runId','unknown'))" 2>/dev/null)
    green "Comms agent triggered (runId: $RUN_ID)"
  else
    red "Comms agent hook failed: $E2E_RESP"
  fi
else
  red "Skipped (no hooks token)"
fi

# Summary
echo ""
echo "=== Results: $PASS passed, $FAIL failed, $WARN warnings ==="
if [ "$FAIL" -gt 0 ]; then
  echo "Some checks failed. Review above."
  exit 1
else
  echo "All critical checks passed. System is operational."
fi
