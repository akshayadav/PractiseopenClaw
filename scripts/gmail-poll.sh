#!/bin/bash
# Gmail poller for OpenClaw
# Polls Pub/Sub + Gmail, analyzes with local ollama, notifies via Telegram
set -euo pipefail

export PATH="$PATH:/home/akshay/.local/bin:/home/akshay/google-cloud-sdk/bin"
ACCOUNT="${GMAIL_ACCOUNT:?Set GMAIL_ACCOUNT}"
PROJECT="${GCP_PROJECT_ID:?Set GCP_PROJECT_ID}"
SUBSCRIPTION="gog-gmail-watch-pull"
STATE_FILE="/home/akshay/.openclaw/scripts/.gmail-last-history"
LOG_FILE="/tmp/openclaw/gmail-poll.log"
BOT_TOKEN="${TELEGRAM_BOT_TOKEN:?Set TELEGRAM_BOT_TOKEN}"
CHAT_ID="${TELEGRAM_CHAT_ID:?Set TELEGRAM_CHAT_ID}"
OLLAMA_URL="http://localhost:11434/api/chat"
TMP_DIR="/tmp/openclaw/gmail-work"

mkdir -p /tmp/openclaw "$TMP_DIR"

log() { echo "$(date -Iseconds) $*" >> "$LOG_FILE"; }

# Pull from Pub/Sub (non-blocking)
PUBSUB_COUNT=0
PULL_RESULT=$(gcloud pubsub subscriptions pull "$SUBSCRIPTION" --project="$PROJECT" --auto-ack --limit=5 --format=json 2>/dev/null) && {
  PUBSUB_COUNT=$(echo "$PULL_RESULT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(len(d))" 2>/dev/null || echo "0")
}

# Always check for unread emails
RESULT=$(gog gmail messages list 'is:unread newer_than:5m' -a "$ACCOUNT" --json --max 5 --include-body 2>/dev/null) || exit 0
COUNT=$(echo "$RESULT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(len(d.get('messages',[])))" 2>/dev/null || echo "0")

if [ "$COUNT" = "0" ] || [ "$COUNT" = "" ]; then
  exit 0
fi

# Deduplicate by message ID
MSG_IDS=$(echo "$RESULT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(' '.join(m.get('id','') for m in d.get('messages',[])))" 2>/dev/null)

if [ -f "$STATE_FILE" ]; then
  PREV_IDS=$(cat "$STATE_FILE")
  NEW_IDS=""
  for id in $MSG_IDS; do
    if ! echo "$PREV_IDS" | grep -qw "$id"; then
      NEW_IDS="$NEW_IDS $id"
    fi
  done
  if [ -z "$(echo $NEW_IDS | tr -d ' ')" ]; then
    exit 0
  fi
fi

echo "$MSG_IDS" > "$STATE_FILE"

log "New emails: $COUNT (pubsub: $PUBSUB_COUNT)"

# Use Python for the rest — safer string handling
echo "$RESULT" | python3 -c '
import sys, json, urllib.request, os

OLLAMA_URL = "http://localhost:11434/api/chat"
BOT_TOKEN = os.environ.get("BOT_TOKEN", "'"$BOT_TOKEN"'")
CHAT_ID = "'"$CHAT_ID"'"
ACCOUNT = "'"$ACCOUNT"'"

# Parse emails
d = json.load(sys.stdin)
msgs = d.get("messages", [])[:5]

# Build email summary
lines = []
for m in msgs:
    frm = m.get("from", "unknown")
    subj = m.get("subject", "(no subject)")
    lines.append(f"From: {frm}")
    lines.append(f"Subject: {subj}")
    body = m.get("body", "")[:500].replace("\r", "").replace("\n", " ").strip()
    lines.append(f"Body: {body}")
    lines.append("")
email_content = "\n".join(lines)

# Analyze with local ollama
analysis = "Analysis unavailable"
try:
    payload = json.dumps({
        "model": "qwen2.5:3b",
        "stream": False,
        "messages": [
            {"role": "system", "content": "You are Comms, a communications analyst. Analyze emails concisely. For each: sender, subject, urgency (low/medium/high), recommended action. Be brief."},
            {"role": "user", "content": f"Analyze these new emails:\n\n{email_content}"}
        ]
    }).encode()
    req = urllib.request.Request(OLLAMA_URL, data=payload, headers={"Content-Type": "application/json"})
    resp = urllib.request.urlopen(req, timeout=60)
    data = json.loads(resp.read())
    analysis = data.get("message", {}).get("content", "Analysis failed")
except Exception as e:
    analysis = f"Analysis unavailable: {e}"

# Send to Telegram
msg = f"\U0001f4e8 Comms Report \u2014 {ACCOUNT}\n\n{email_content}\n\U0001f4cb Analysis:\n{analysis}"
tg_payload = json.dumps({"chat_id": CHAT_ID, "text": msg}).encode()
tg_req = urllib.request.Request(
    f"https://api.telegram.org/bot{BOT_TOKEN}/sendMessage",
    data=tg_payload,
    headers={"Content-Type": "application/json"}
)
try:
    tg_resp = urllib.request.urlopen(tg_req, timeout=10)
    print(tg_resp.read().decode())
except Exception as e:
    print(f"Telegram send failed: {e}", file=sys.stderr)
'

log "Comms analysis sent to Telegram"
