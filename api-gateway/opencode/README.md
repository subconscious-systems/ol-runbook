# Using OpenCode with Subconscious API Gateway

[OpenCode](https://opencode.ai) is an open-source AI coding agent. This guide
routes it through your Subconscious API Gateway with conversation correlation
so requests are grouped in the dashboard **Conversations** view.

## How it works

OpenCode natively sends `x-session-affinity` and `X-Session-Id` headers on
every request (and `x-parent-session-id` for sub-agent sessions). The gateway
uses these to group requests into conversations.

The install script also sets `x-subconscious-client: opencode` as a custom
provider header, which unambiguously identifies the agent to the gateway
regardless of session-header heuristics.

## Requirements

- `jq`
- A gateway API key (create one in the Subconscious dashboard)
- Gateway URL reachable from your machine

## Install

```bash
cd ol-runbook/api-gateway/opencode
chmod +x install.sh
./install.sh install \
  --gateway-url 'https://your-gateway.example' \
  --api-key 'sk-...'
```

This writes `~/.opencode/opencode.json` and `~/.opencode/subconscious.env`
(mode 600). Source the env file or export `SUBCONSCIOUS_API_KEY` in your shell
profile, then launch opencode.

Check status / uninstall:

```bash
./install.sh status
./install.sh uninstall
```

## Manual setup

If you prefer to configure opencode manually, set these in your
`opencode.json`:

```json
{
  "$schema": "https://opencode.ai/config.json",
  "provider": {
    "subconscious": {
      "npm": "@ai-sdk/openai-compatible",
      "name": "Subconscious Gateway",
      "options": {
        "baseURL": "https://your-gateway.example/v1",
        "apiKey": "{env:SUBCONSCIOUS_API_KEY}",
        "headers": {
          "x-subconscious-client": "opencode"
        }
      },
      "models": {
        "gw-glm-5.2": {
          "name": "gw-glm-5.2",
          "tools": true
        }
      }
    }
  },
  "model": "subconscious/gw-glm-5.2"
}
```

Export the API key:

```sh
export SUBCONSCIOUS_API_KEY="sk-gw-..."
```

## What gets installed

| Path | Purpose |
| --- | --- |
| `~/.opencode/opencode.json` | Provider config pointing to your gateway with `x-subconscious-client` header |
| `~/.opencode/subconscious.env` | `SUBCONSCIOUS_API_KEY` env var (mode 600) |

## Conversation correlation

The gateway detects OpenCode via two mechanisms (checked in order):

1. **`x-subconscious-client: opencode`** — explicit override, always wins
2. **`x-session-affinity` + `x-session-id`** — native OpenCode headers (heuristic fallback)

Sub-agent sessions (`x-parent-session-id`) are linked to their parent
conversation in the dashboard.
