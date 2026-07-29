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

## Shared env (preferred)

All scripts read `GATEWAY_URL`, `API_KEY`, and optional `MODEL` from the shared
`coding-agents/.env` one level up. Set that once, then run install/run without
passing credentials on the command line:

```bash
cd ol-runbook/coding-agents
cp env.example .env   # one-time: paste GATEWAY_URL + API_KEY
```

`--gateway-url` / `--api-key` flags still override `.env` when you need a
one-off value.

## Install

```bash
cd ol-runbook/coding-agents
./opencode/install.sh    # reads GATEWAY_URL + API_KEY from .env
```

`install` is the default subcommand and may be omitted.

This writes `~/.opencode/opencode.json` and `~/.opencode/subconscious.env`
(mode 600). Source the env file or export `SUBCONSCIOUS_API_KEY` in your shell
profile, then launch opencode.

Check status / uninstall:

```bash
./opencode/install.sh status
./opencode/install.sh uninstall
```

## Ephemeral runner (no persistent config)

If you don't want to write anything to `~/.opencode/`, use `run.sh` instead.
It exports `SUBCONSCIOUS_API_KEY` and `OPENCODE_CONFIG_CONTENT` as env vars
and launches opencode — nothing is written to disk.

```bash
cd ol-runbook/coding-agents
# ensure .env is filled in (see above)
./opencode/run.sh             # launch opencode
./opencode/run.sh -- auth     # pass args through
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
