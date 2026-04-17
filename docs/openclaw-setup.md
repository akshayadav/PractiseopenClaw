---
name: OpenClaw Jetson Setup
description: Complete OpenClaw architecture on Jetson Orin Nano — agents, models, tools profiles, hooks API, Gmail pipeline, and troubleshooting guide
type: project
---

# OpenClaw on Jetson Orin Nano

## Network

- **Jetson IP:** `<JETSON_IP>` (SSH key auth)
- **Mac (LM Studio):** `<MAC_IP>:1234`

## Architecture

```
Captain (lead agent, default)
  model: lmstudio/google/gemma-4 (on Mac)
  workspace: ~/.openclaw/workspace
  can spawn: comms, laala, scout

Comms (communications)    — ollama/qwen2.5:3b (local Jetson)
Laala (shopping)          — ollama/qwen2.5:3b (local Jetson)
Scout (research)          — ollama/qwen2.5:3b (local Jetson)
```

**Key rule:** Sub-agents use the local Jetson model (ollama/qwen2.5:3b). Only Captain uses the remote Mac model.

## Config File

`/home/akshay/.openclaw/openclaw.json` — gateway hot-reloads most changes automatically.

## Model Providers

| Provider | Base URL | Model | Used By |
|----------|----------|-------|---------|
| lmstudio | http://<MAC_IP>:1234/v1 | google/gemma-4 | Captain |
| ollama | http://localhost:11434/v1 | qwen2.5:3b | Comms, Laala, Scout |

## Gateway

- **Port:** 18789 (loopback only)
- **Auth token:** `<GATEWAY_AUTH_TOKEN>` (set in openclaw.json gateway.auth.token)
- **Service:** `systemctl --user status openclaw-gateway`
- **Logs:** `/tmp/openclaw/openclaw-YYYY-MM-DD.log`

## Telegram

- **Bot:** @Bunty2_bot (token in openclaw.json channels.telegram.botToken)
- **Chat ID:** `<TELEGRAM_CHAT_ID>`

---

# Tools Profiles — CRITICAL

OpenClaw has three tools profiles that control which tool schemas are injected into the system prompt:

| Profile | Includes | Prompt Size Impact |
|---------|----------|-------------------|
| `minimal` | Basic tools only | Smallest prompt |
| `messaging` | + messaging tools | Medium |
| `coding` | + exec, sessions_spawn, subagents, fs tools | Largest prompt |

**Current setting:** `tools.profile: "minimal"` (to fit gemma-4's context window)

### Which tools are in which profile

Found by reverse-engineering `tool-policy-dLQuqjVi.js`:

- **`exec` (shell commands):** `coding` only
- **`sessions_spawn` (spawn subagents):** `coding` only
- **`subagents` group:** `coding` only
- **`sessions_send`, `sessions_list`:** `coding` and `messaging`
- **Tools in ALL profiles (minimal+):** at least one group exists with `["minimal", "coding", "messaging"]`

### tools.alsoAllow — Surgical tool additions

To add specific tools without changing the whole profile, use `tools.alsoAllow` in openclaw.json:

```json
"tools": {
  "profile": "minimal",
  "alsoAllow": [
    "sessions_spawn",
    "sessions_list",
    "sessions_send",
    "sessions_history",
    "session_status"
  ]
}
```

**Current alsoAllow:** `ollama_web_search`, `ollama_web_fetch`, `sessions_spawn`, `sessions_list`, `sessions_send`, `sessions_history`, `session_status`

### Subagent prompt mode

Subagents and cron sessions always run in `minimal` prompt mode regardless of the parent's profile. This is hardcoded:
```js
const promptMode = isSubagentSessionKey(params.sessionKey) || isCronSessionKey(params.sessionKey) ? "minimal" : "full";
```

This means subagents have very limited tools. If a subagent needs shell access, either:
1. Add `exec` to the agent's tools config (not yet tested)
2. Bypass the agent framework and call the model directly (what we do for Gmail)

---

# Hooks API

## Activation

The hooks system requires **both**:
1. `hooks.enabled: true` in openclaw.json
2. `hooks.token` set to a bearer token

Without `hooks.enabled: true`, the `/hooks/*` endpoints return 404 (the handler returns false and the request falls through).

## Endpoints

### POST /hooks/agent
Triggers an isolated agent run. Auth: `Authorization: Bearer <hooks.token>`

```bash
curl -X POST http://127.0.0.1:18789/hooks/agent \
  -H "Authorization: Bearer <HOOKS_TOKEN>" \
  -H "Content-Type: application/json" \
  -d '{
    "agentId": "comms",
    "message": "Your task here",
    "name": "task-name",
    "wakeMode": "now",
    "deliver": true,
    "channel": "telegram",
    "to": "<TELEGRAM_CHAT_ID>"
  }'
```

Response: `{"ok": true, "runId": "uuid"}`

This creates a one-shot cron job that runs the specified agent with the message. The agent runs in `minimal` prompt mode with `ollama/qwen2.5:3b`.

### POST /hooks/wake
Wakes the main agent session with a system event.

### Gmail hook preset
Configured via `hooks.presets: ["gmail"]` and `hooks.gmail` config. Requires `gog gmail watch serve` with a public URL (Tailscale Funnel or similar) to work as push. Currently non-functional because no public URL is available.

## Hooks tokens

- **hooks.token:** `<HOOKS_TOKEN>` (for /hooks/* API, set in openclaw.json hooks.token)
- **gateway.auth.token:** `<GATEWAY_AUTH_TOKEN>` (for gateway API, set in openclaw.json gateway.auth.token)

These are different tokens for different purposes.

---

# Gmail Pipeline

## Account: <GMAIL_ACCOUNT>

### Google Cloud Setup
- **Project:** `<GCP_PROJECT_ID>`
- **OAuth client:** `<OAUTH_CLIENT_ID>.apps.googleusercontent.com`
- **Pub/Sub topic:** `projects/<GCP_PROJECT_ID>/topics/gog-gmail-watch`
- **Pub/Sub subscription:** gog-gmail-watch-pull (pull mode)
- **Gmail Watch:** registered via `gog gmail watch start`

### gog CLI
- **Path:** `/home/akshay/.local/bin/gog` (v0.12.0, from github.com/steipete/gogcli)
- **Credentials:** `/home/akshay/.config/gogcli/credentials.json`
- **Token:** Authenticated via export/import from Mac (Jetson can't do OAuth callback)
- **Refresh:** If token expires, re-auth on Mac with `gog auth login`, then `gog auth tokens export > /tmp/tokens.json`, copy to Jetson, `gog auth tokens import < /tmp/tokens.json`

### Polling Script
**Path:** `/home/akshay/.openclaw/scripts/gmail-poll.sh`
**Cron:** `*/3 * * * *` (every 3 minutes)
**Flow:**
1. Pull Pub/Sub notifications (non-blocking)
2. Query Gmail for unread emails newer than 5 minutes
3. Deduplicate by message ID (state file: `.gmail-last-history`)
4. Call ollama/qwen2.5:3b directly for email analysis (bypasses OpenClaw to avoid system prompt overhead)
5. Send combined report (email + analysis) to Telegram via Bot API

**Why direct ollama instead of OpenClaw hooks/agent:**
- OpenClaw adds ~7500 tokens of system prompt + security notices
- qwen2.5:3b (3B model) produces empty responses when overwhelmed with large prompts
- Direct ollama call: ~100 input tokens, reliable analysis output

**Logs:** `/tmp/openclaw/gmail-poll.log`

---

# Troubleshooting Guide

## Agent not spawning subagents

**Symptom:** Captain says "I'll spawn agent X" but nothing happens in logs.

**Check:**
1. Does the tools profile include `sessions_spawn`?
   - `minimal` and `messaging` do NOT include it
   - Either switch to `coding` or add to `tools.alsoAllow`:
     ```json
     "tools": { "alsoAllow": ["sessions_spawn", "sessions_list", "sessions_send"] }
     ```
2. Is the agent listed in `subagents.allowAgents`?
3. Check logs: `grep -i 'spawn\|subagent\|session' /tmp/openclaw/openclaw-$(date +%Y-%m-%d).log`

## Agent produces empty responses

**Symptom:** Session transcript shows `"content":[]` with some output tokens.

**Cause:** System prompt too large for the model. OpenClaw adds security notices, tool schemas, bootstrap context.

**Fix:**
- For small models (3B), bypass OpenClaw and call ollama directly
- Or reduce tools.profile to `minimal` and minimize alsoAllow
- Check input token count in session file — if >5000 for a 3B model, expect issues

## /hooks/* endpoints returning 404

**Check:**
1. Is `hooks.enabled: true` set? (This is the #1 missed setting)
2. Is `hooks.token` set?
3. Both are required. Without `hooks.enabled`, the handler returns false and requests fall through to generic 404.
4. After setting, check logs for: `config hot reload applied (hooks.enabled)`

## "tokens to keep from initial prompt > context length"

**Cause:** System prompt + tool schemas exceed model's context window.

**Fix:**
1. Reduce `tools.profile` (coding > messaging > minimal)
2. Remove unnecessary tools from `alsoAllow`
3. Increase context length in LM Studio (for gemma-4 on Mac)
4. After changes, restart gateway: `systemctl --user restart openclaw-gateway`

## Telegram "terminated by other getUpdates request"

**Cause:** Two processes polling the same bot token — either two gateway instances, or the gmail-poll script's `sendMessage` conflicting briefly.

**Fix:**
- Ensure only one gateway instance: `systemctl --user status openclaw-gateway`
- The `sendMessage` API (used by gmail-poll) does NOT conflict with `getUpdates` — this error is transient and self-resolves
- If persistent, check for stale processes: `ps aux | grep openclaw`

## Gmail OAuth token expired

**Symptom:** gog commands fail with auth errors.

**Fix (must be done on Mac, not Jetson):**
1. On Mac: `gog auth login -a <GMAIL_ACCOUNT>`
2. Export: `gog auth tokens export > /tmp/gog-tokens.json`
3. Copy to Jetson: `scp /tmp/gog-tokens.json <user>@<JETSON_IP>:/tmp/`
4. On Jetson: `gog auth tokens import < /tmp/gog-tokens.json`

**Why not on Jetson:** OAuth requires browser callback to 127.0.0.1:random-port. SSH sessions can't handle this without port forwarding, and gog's timeout is too short.

## Gateway won't start / model errors

**Check:**
1. Is LM Studio running on Mac? `curl http://<MAC_IP>:1234/v1/models`
2. Is ollama running on Jetson? `curl http://localhost:11434/api/tags`
3. "Failed to discover vLLM models" warnings are normal (no vLLM configured, safe to ignore)
4. Restart: `systemctl --user restart openclaw-gateway`

---

# Key Files on Jetson

| Path | Purpose |
|------|---------|
| `~/.openclaw/openclaw.json` | Main config (hot-reloads) |
| `~/.openclaw/workspace/` | Captain's workspace |
| `~/.openclaw/agents/comms/workspace/SOUL.md` | Comms identity/instructions |
| `~/.openclaw/agents/comms/sessions/` | Comms session transcripts |
| `~/.openclaw/scripts/gmail-poll.sh` | Gmail polling + analysis cron script |
| `~/.openclaw/scripts/.gmail-last-history` | Dedup state (message IDs) |
| `~/.config/gogcli/credentials.json` | Google OAuth credentials |
| `~/.config/systemd/user/openclaw-gateway.service` | systemd service |
| `/tmp/openclaw/openclaw-YYYY-MM-DD.log` | Gateway logs |
| `/tmp/openclaw/gmail-poll.log` | Gmail poll logs |
