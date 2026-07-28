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

## Requirements

- `jq`
- A gateway API key (create one in the Subconscious dashboard)
- Gateway URL reachable from your machine

## Install

```bash
cd ol-runbook/coding-agents/pi
chmod +x install.sh
./install.sh install \
  --gateway-url 'https://your-gateway.example' \
  --api-key 'sk-...'
```

This writes `~/.pi/agent/models.json` (mode 600, includes the API key).
Restart any running Pi sessions.

Check status / uninstall:

```bash
./install.sh status
./install.sh uninstall
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

## Session affinity formats

Pi supports several `sessionAffinityFormat` values. The recommended format for
gateway use is `openai-nosession`:

| Format | Headers sent | Recommended? |
| --- | --- | --- |
| `openai-nosession` | `x-client-request-id`, `x-session-affinity` | **Yes** — avoids underscore `session_id` |
| `openai` | `session_id`, `x-client-request-id`, `x-session-affinity` | Works, but `session_id` (underscore) may be dropped by strict proxies |
| `openrouter` | `x-session-id` | Works, but less efficient (no `x-session-affinity` for cache routing) |
| *(none)* | none | Not tracked — Pi sends no session headers by default |
