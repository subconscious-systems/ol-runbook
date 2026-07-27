# Using Cursor with Subconscious API Gateway

First go into Cursor settings and enable the "OpenAI API Key Override" setting. Follow these LiteLLM docs for a similar setup: https://docs.litellm.ai/docs/tutorials/cursor_integration

Use base url `https://<your-gateway-url>`, an API key from the Subconscious dashboard, and the configured model name from the dashboard.

# Cursor hooks — Conversations correlation

Install local [Cursor hooks](https://cursor.com/docs/hooks.md) that announce each agent handoff to your Subconscious gateway. The gateway groups `/v1/chat/completions` (and related) requests into the dashboard **Conversations** view.

Hooks **cannot** inject headers into model HTTP. They `POST /v1/agent-hooks` with a prompt fingerprint; the gateway soft-binds later LLM requests that share that fingerprint.

## Requirements

- `jq`, `curl`
- `openssl` or `shasum` (SHA-256)
- A gateway API key (same key as Cursor’s OpenAI override)
- Gateway URL reachable from your machine

## Install

```bash
cd ol-runbook/api-gateway/cursor
chmod +x install.sh hook.sh
./install.sh install \
  --gateway-url 'https://your-gateway.example' \
  --api-key 'sk-...'
```

Restart Cursor fully so it reloads `~/.cursor/hooks.json`.

Check status / uninstall:

```bash
./install.sh status
./install.sh uninstall
```

Hooks install **user-wide** under `~/.cursor` only (API key stays out of git working trees).

## What gets installed

| Path | Purpose |
| --- | --- |
| `~/.cursor/hooks/subconscious-hook.sh` | Fail-open hook script |
| `~/.cursor/subconscious-hooks.env` | `SUBCONSCIOUS_GATEWAY_URL` + `SUBCONSCIOUS_API_KEY` (mode 600) |
| `~/.cursor/hooks.json` | Merges `beforeSubmitPrompt`, `afterAgentResponse`, `stop` |

## Fingerprint contract

Both the hook and the gateway normalize then SHA-256:

1. Replace `\r\n` with `\n` (hook strips `\r`)
2. Trim leading/trailing whitespace
3. SHA-256 hex (64 lowercase hex chars) → `prompt_fp`

Fixture (must match gateway unit tests):

| Input | `prompt_fp` |
| --- | --- |
| `fix` | `1c6e6c4c02e55178e85890fc9bbed4ce046415ec8122bf38f711b779184ae2a0` |
| `hello\r\nworld  ` equals `hello\nworld` after normalize | same hash |

## Events

| Cursor hook | Gateway event |
| --- | --- |
| `beforeSubmitPrompt` | `turn_open` (+ `prompt_fp`) |
| `afterAgentResponse` | `turn_heartbeat` |
| `stop` | `turn_close` |

Same Cursor `conversation_id` across multiple user sends upserts one Conversations row. Each send opens a new generation window (`generation_id` + `prompt_fp`).
