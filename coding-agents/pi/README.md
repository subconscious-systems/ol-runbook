# Using Pi with Subconscious API Gateway

[Pi](https://pi.ai) is an AI coding agent. This guide routes it through your
Subconscious API Gateway with conversation correlation so requests are grouped
in the dashboard **Conversations** view.

## How it works

Pi does **not** send session headers by default. To get conversation grouping,
you need two things in your `models.json`:

1. **`x-subconscious-client: pi`** — a custom provider header that
   unambiguously identifies the agent to the gateway (always wins, checked
   first).

2. **`sendSessionAffinityHeaders: true`** with **`sessionAffinityFormat:
   "openai-nosession"`** — enables Pi's native session headers
   (`x-session-affinity`) so the gateway has a session ID to group requests
   into conversations. The `openai-nosession` format avoids the underscore
   `session_id` header that strict proxies may drop.

### Token reporting and compaction

Use an API key with **Full list context** reporting (edit the key in the
dashboard if it still says TIMRUN - new keys default to TIMRUN). Set
`contextWindow` / `maxTokens` on the model (installer defaults `5000000` /
`65536`) and leave Pi auto-compaction on so it fires when
`contextTokens > contextWindow - reserveTokens`.

Docs: [Pi compaction](https://github.com/badlogic/pi-mono/blob/main/packages/coding-agent/docs/compaction.md).

## Requirements

- `jq`
- A gateway API key (create one in the Subconscious dashboard)
- Gateway URL reachable from your machine

## Shared env (preferred)

Prefer the shared `coding-agents/.env` one level up for `GATEWAY_URL`,
`API_KEY` (or `PI_API_KEY`), and optional `MODEL`. Set that once, then install
without flags. Prefer a **Full list** key via `PI_API_KEY` when `API_KEY` is
TIMRUN for other agents.

```bash
cd ol-runbook/coding-agents
cp env.example .env   # one-time: paste GATEWAY_URL + API_KEY
```

`--gateway-url` / `--api-key` flags still override `.env` when you need a
one-off value.

## Install

```bash
cd ol-runbook/coding-agents
chmod +x pi/install.sh
./pi/install.sh    # reads GATEWAY_URL + API_KEY from .env
```

`install` is the default subcommand and may be omitted.

This writes `~/.pi/agent/models.json` (mode 600, includes the API key).
Restart any running Pi sessions.

Check status / uninstall:

```bash
./pi/install.sh status
./pi/install.sh uninstall
```

## Manual setup

If you prefer to configure Pi manually, set this in your
`~/.pi/agent/models.json`:

```json
{
  "providers": {
    "subconscious": {
      "baseUrl": "https://your-gateway.example/v1",
      "api": "openai-completions",
      "apiKey": "sk-gw-...",
      "headers": {
        "x-subconscious-client": "pi"
      },
      "models": [
        {
          "id": "gw-glm-5.2",
          "contextWindow": 5000000,
          "maxTokens": 65536,
          "compat": {
            "sendSessionAffinityHeaders": true,
            "sessionAffinityFormat": "openai-nosession"
          }
        }
      ]
    }
  }
}
```

## What gets installed

| Path | Purpose |
| --- | --- |
| `~/.pi/agent/models.json` | Provider config with `x-subconscious-client` header + session affinity compat |

## Conversation correlation

The gateway detects Pi via two mechanisms (checked in order):

1. **`x-subconscious-client: pi`** — explicit override, always wins
2. **`x-session-affinity`** (without `x-session-id`) — Pi's native session
   header when `sendSessionAffinityHeaders` is enabled (heuristic fallback)

Without `sendSessionAffinityHeaders: true`, Pi sends no session headers and
traffic will appear on the **Requests** view only (not grouped into
Conversations).

Auto-compaction uses `contextWindow` on the model entry
(`contextTokens > contextWindow - reserveTokens`). The installer sets
`contextWindow: 5000000` by default. Override with `--context-window` /
`PI_CONTEXT_WINDOW`. Compaction knobs (`reserveTokens`, `keepRecentTokens`)
live in `~/.pi/agent/settings.json` — see
[Pi compaction docs](https://github.com/badlogic/pi-mono/blob/main/packages/coding-agent/docs/compaction.md).

### Subagent plugin (`pi install npm:pi-subagents`)

When you use the Pi subagent plugin (`pi install npm:pi-subagents`), each
subagent conversation is treated as its **own** conversation by the gateway.
The parent session and its spawned subagents are **not currently correlated**
back together - subagent traffic will not have a link back to the parent session.

## Session affinity formats

Pi supports several `sessionAffinityFormat` values. The recommended format for
gateway use is `openai-nosession`:

| Format | Headers sent | Recommended? |
| --- | --- | --- |
| `openai-nosession` | `x-client-request-id`, `x-session-affinity` | **Yes** — avoids underscore `session_id` |
| `openai` | `session_id`, `x-client-request-id`, `x-session-affinity` | Works, but `session_id` (underscore) may be dropped by strict proxies |
| `openrouter` | `x-session-id` | Works, but less efficient (no `x-session-affinity` for cache routing) |
| *(none)* | none | Not tracked — Pi sends no session headers by default |
