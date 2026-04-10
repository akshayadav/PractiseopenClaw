---
name: OpenClaw tools and hooks gotchas
description: Critical pitfalls when debugging OpenClaw agent spawning, tools availability, hooks API 404s, and small model prompt overflow
type: feedback
---

When debugging OpenClaw agent issues, always check these first:

1. **`hooks.enabled: true` is required** for /hooks/* endpoints. Without it, all hook requests silently return 404. This is separate from `hooks.internal.enabled`.
   **Why:** We spent significant time getting 404s from /hooks/agent before discovering this flag in the source code.
   **How to apply:** If any /hooks/* endpoint returns 404, first check `hooks.enabled` in openclaw.json before investigating further.

2. **`tools.profile: "minimal"` excludes `sessions_spawn` and `exec`.** Captain cannot spawn subagents unless `sessions_spawn` is in `tools.alsoAllow` or the profile is `coding`.
   **Why:** Captain hallucinated "I'll spawn the Comms agent" but never made the tool call because the tool wasn't available in minimal profile.
   **How to apply:** If an agent claims it will spawn/delegate but logs show no subagent activity, check the tools profile and alsoAllow list.

3. **Small models (3B) fail silently with large OpenClaw system prompts.** qwen2.5:3b produces empty `"content":[]` responses when OpenClaw's ~7500 token system prompt is injected.
   **Why:** OpenClaw adds security notices, tool schemas, and bootstrap context that overwhelm small models.
   **How to apply:** For tasks targeting small local models, call ollama directly instead of routing through OpenClaw's agent framework. The gmail-poll script does this for email analysis.

4. **Subagents always run in `minimal` prompt mode** regardless of parent config. This is hardcoded. Don't expect subagents to have tools that only exist in `coding` or `messaging` profiles.
   **Why:** Discovered in source: `isSubagentSessionKey() || isCronSessionKey() ? "minimal" : "full"`
   **How to apply:** When designing subagent tasks, ensure they don't require tools outside minimal profile, or work around it.
