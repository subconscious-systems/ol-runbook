# Using Codex with Subconscious API Gateway

[Codex](https://github.com/openai/codex) is OpenAI's CLI coding agent. This
guide routes it through your Subconscious API Gateway with conversation
correlation so requests are grouped in the dashboard **Conversations** view.

## How it works

Codex natively sends `thread-id`, `session-id`, and `x-codex-turn-metadata`
headers on every request (and `x-codex-parent-thread-id` for sub-agent
sessions). The gateway uses these to group requests into conversations.

The install script also sets `wire_api = "responses"` so Codex uses the
gateway's `POST /v1/responses` endpoint, and `env_key = "SUBCONSCIOUS_API_KEY"`
for authentication. Web search is disabled (`web_search = "disabled"`) so
Codex doesn't send hosted tools the gateway can't execute.

## Requirements

- A gateway API key (create one in the Subconscious dashboard)
- Gateway URL reachable from your machine

## Quick start (ephemeral — no persistent config)

`run.sh` launches Codex with `-c` flags + a temp model catalog — nothing is
written to `~/.codex/config.toml`. The temp catalog is cleaned up on exit.

```bash
cd ol-runbook/coding-agents
cp env.example .env      # one-time setup (shared at coding-agents/ level)
./codex/run.sh                        # uses GATEWAY_URL/API_KEY from .env
./codex/run.sh -- --resume            # pass args through to codex
```

Or source it to just export env:

```bash
source codex/run.sh
```

## Install (persistent config)

```bash
cd ol-runbook/coding-agents/codex
chmod +x install.sh
./install.sh \
  --gateway-url 'https://your-gateway.example' \
  --api-key 'sk-gw-...'
```

`install` is the default subcommand and may be omitted.

This writes `~/.codex/config.toml` and `~/.codex/subconscious.env`
(mode 600).

## Launch

After install, launch codex with the gateway env loaded:

```bash
./install.sh use                    # launches codex
./install.sh use -- --resume        # pass args through to codex
```

Or load the env into your current shell without launching:

```bash
source <(./install.sh env)          # load   SUBCONSCIOUS_API_KEY
source <(./install.sh unset)        # remove SUBCONSCIOUS_API_KEY
```

Check status / uninstall:

```bash
./install.sh status
./install.sh uninstall
```

## Manual setup

If you prefer to configure Codex manually, you need two files. First, create
`~/.codex/model-catalog.json` to register the model (without this, Codex prints
a "Model metadata not found" warning on every turn):

```json
{
  "models": [
    {
      "slug": "gw-glm-5.2",
      "display_name": "Subconscious GLM 5.2",
      "description": "Subconscious API Gateway GLM 5.2",
      "context_window": 200000,
      "max_context_window": 200000,
      "auto_compact_token_limit": 180000,
      "effective_context_window_percent": 95,
      "supported_reasoning_levels": [],
      "shell_type": "shell_command",
      "visibility": "list",
      "supported_in_api": true,
      "priority": 0,
      "availability_nux": null,
      "upgrade": null,
      "base_instructions": "You are Codex, a coding agent.",
      "supports_reasoning_summaries": false,
      "support_verbosity": false,
      "default_verbosity": null,
      "apply_patch_tool_type": "freeform",
      "truncation_policy": { "mode": "tokens", "limit": 10000 },
      "supports_parallel_tool_calls": true,
      "experimental_supported_tools": []
    }
  ]
}
```

Then set these in your `~/.codex/config.toml`:

```toml
model = "gw-glm-5.2"
model_provider = "subconscious"
model_catalog_json = "~/.codex/model-catalog.json"
web_search = "disabled"

[model_providers.subconscious]
name = "Subconscious Gateway"
base_url = "https://your-gateway.example/v1"
wire_api = "responses"
env_key = "SUBCONSCIOUS_API_KEY"
stream_idle_timeout_ms = 300000
```

Export the API key:

```sh
export SUBCONSCIOUS_API_KEY="sk-gw-..."
codex
```

Or pass everything inline without a config file:

```sh
export SUBCONSCIOUS_API_KEY="sk-gw-..."
codex \
  -c model_providers.subconscious.name=Subconscious \
  -c model_providers.subconscious.base_url=https://your-gateway.example/v1 \
  -c model_providers.subconscious.env_key=SUBCONSCIOUS_API_KEY \
  -c model_provider=subconscious \
  -c model=gw-glm-5.2
```

> **Note:** Without `model_catalog_json`, Codex will still work but prints a
> warning and uses degraded defaults (wrong context window, no auto-compact).

## What gets installed

| Path | Purpose |
| --- | --- |
| `~/.codex/config.toml` | Provider config pointing to your gateway with `wire_api = "responses"` and `web_search = "disabled"` |
| `~/.codex/model-catalog.json` | Model metadata catalog (context window, tool support) so Codex doesn't print a "Model metadata not found" warning |
| `~/.codex/subconscious.env` | `SUBCONSCIOUS_API_KEY` env var (mode 600) |

## Conversation correlation

The gateway detects Codex via two mechanisms (checked in order):

1. **`x-subconscious-client: codex`** — explicit override, always wins
2. **`thread-id` / `x-codex-turn-metadata` / `session-id`** — native Codex headers (heuristic fallback)

Sub-agent sessions (`x-codex-parent-thread-id`) are linked to their parent
conversation in the dashboard.
