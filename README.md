# OpenClaw on Jetson Orin Nano + Mac Mini

A fully local multi-agent AI system running on edge hardware. No cloud inference APIs.

## Architecture

- **Captain** (Google Gemma 3 12B) on Mac Mini 16GB via LM Studio -- lead orchestrator
- **Comms, Scout, Laala** (Qwen 2.5 3B) on Jetson Orin Nano via Ollama -- specialist sub-agents
- **Telegram** as the user interface
- **Gmail monitoring** via Google Cloud Pub/Sub + cron polling

## What's Here

```
docs/
  openclaw-setup.md          # Full setup guide, config reference, troubleshooting
  tools-hooks-gotchas.md     # Critical pitfalls learned the hard way
scripts/
  gmail-poll.sh              # Gmail polling + local LLM analysis + Telegram notification
```

## Key Decisions

**Why Gemma 3 12B over Qwen 3 8B for Captain?**
Better multi-tool orchestration, multimodal (text + images), reliable instruction following for delegation tasks. Fits in 16GB RAM.

**Why Qwen 2.5 3B for sub-agents?**
The Jetson has real VRAM constraints. 3B returns email analysis in 6 seconds. A 7B takes 40+ or crashes.

**Why bypass OpenClaw's agent framework for sub-agent tasks?**
OpenClaw injects ~7,500 tokens of system scaffolding into every agent prompt. The 3B model produces empty responses when overwhelmed. Calling Ollama directly with ~100 tokens works reliably.

## Setup

See [docs/openclaw-setup.md](docs/openclaw-setup.md) for the complete guide.

## Troubleshooting

See the troubleshooting section in [docs/openclaw-setup.md](docs/openclaw-setup.md) and [docs/tools-hooks-gotchas.md](docs/tools-hooks-gotchas.md).
