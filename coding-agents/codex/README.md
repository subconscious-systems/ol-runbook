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

### Token reporting and compaction

Use an API key with **TIMRUN context** reporting (the default for new keys).
TIMRUN-reported `input_tokens` stay near the retained window (typically well
under ~150k), so Codex auto-compaction driven by the model catalog almost never
fires even though our catalog windows are large (`context_window` /
`auto_compact_token_limit` defaults `5000000` / `4500000`). Leave catalog
auto-compact enabled. If request bodies grow too large (gateway **50 MiB**) or
round-trips feel slow, compact or start a fresh thread manually.

When compaction does run, custom (non-OpenAI-named) providers use the local
path that calls the active model over Responses - so the summarization request
hits your gateway. The installer registers [Codex hooks](https://developers.openai.com/codex/hooks)
(`PreCompact` / `PostCompact`) that report `conversation_compaction` start/end
so that turn is billed as compaction rather than as a main-thread peak.

After install, trust the new hooks in the CLI with `/hooks` (Codex skips
untrusted hooks), then start a **new** Codex session so discovery picks up the
trusted handlers - a session that began while hooks were still untrusted will
not run them. For one-off automation you can pass
`--dangerously-bypass-hook-trust`.

Related upstream notes (no first-party “raise auto-compact past product
defaults” page comparable to Claude Code):
[openai/codex#19409](https://github.com/openai/codex/issues/19409) (catalog /
auto-compact mismatch),
[openai/codex#11805](https://github.com/openai/codex/issues/11805) (90% clamp).

## Requirements

- A gateway API key (create one in the Subconscious dashboard)
- Gateway URL reachable from your machine

## Shared env (preferred)

All scripts read `GATEWAY_URL`, `API_KEY` (or `CODEX_API_KEY`), and optional
`MODEL` from the shared `coding-agents/.env` one level up. Set that once, then
run install/run without passing credentials on the command line. `CODEX_API_KEY`
overrides shared `API_KEY` when set.

```bash
cd ol-runbook/coding-agents
cp env.example .env   # one-time: paste GATEWAY_URL + API_KEY
```

`--gateway-url` / `--api-key` flags still override `.env` when you need a
one-off value.

## Quick start (ephemeral — no persistent config)

`run.sh` launches Codex with `-c` flags + a temp model catalog — nothing is
written to `~/.codex/config.toml`. The temp catalog is cleaned up on exit.

```bash
cd ol-runbook/coding-agents
# ensure .env is filled in (see above)
./codex/run.sh                        # uses GATEWAY_URL/API_KEY from .env
./codex/run.sh -- --resume            # pass args through to codex
```

Or source it to just export env:

```bash
source codex/run.sh
```

## Install (persistent config)

```bash
cd ol-runbook/coding-agents
chmod +x codex/install.sh
./codex/install.sh    # reads GATEWAY_URL + API_KEY from .env
```

`install` is the default subcommand and may be omitted.

This writes `~/.codex/config.toml` and `~/.codex/subconscious.env`
(mode 600).

## Launch

After install, launch codex with the gateway env loaded:

```bash
./codex/install.sh use                    # launches codex
./codex/install.sh use -- --resume        # pass args through to codex
```

Or load the env into your current shell without launching:

```bash
source <(./codex/install.sh env)          # load   SUBCONSCIOUS_API_KEY
source <(./codex/install.sh unset)        # remove SUBCONSCIOUS_API_KEY
```

Check status / uninstall:

```bash
./codex/install.sh status
./codex/install.sh uninstall
```

## Subagents

### Known limitation: subagents don't work with custom providers

Subagents are **disabled by default**. Current Codex releases (>= 0.144) wrap
subagent tools (`spawn_agent`, etc.) in a proprietary `type: "namespace"` wire
format. Non-OpenAI providers — including the Subconscious gateway — can't
resolve these namespace tools, so Codex emits:

```
unsupported call: spawn_agent
```

This is a known upstream issue ([#32318](https://github.com/openai/codex/issues/32318),
[#26977](https://github.com/openai/codex/issues/26977),
[#17598](https://github.com/openai/codex/issues/17598)). The fix
([PR #29602](https://github.com/openai/codex/pull/29602) — `namespace_tools =
false` provider capability) is not yet merged into any released version.

### Running with subagents (legacy codex@0.132.0)

To use subagents, install the pinned legacy Codex 0.132.0 which uses the
older multi-agent v1 config with **plain tool names** (no namespace wrapper)
that the model worker can resolve:

```bash
# Install codex@0.132.0 globally
npm install -g @openai/codex@0.132.0
```

Run ephemerally:

```bash
./codex/run.sh --subagents
./codex/run.sh --subagents -- --resume
```

Install persistently:
```bash
# Install the gateway config with --subagents
cd ol-runbook/coding-agents
./codex/install.sh --subagents

# Launch
./codex/install.sh use
```

This writes the legacy multi-agent v1 config to `~/.codex/config.toml`:

```toml
[features]
multi_agent = true

[agents]
max_threads = 4
max_depth = 1
interrupt_message = true
```
### Running without subagents (default)

The default install/run path uses the latest Codex with subagents off — no
`[agents]` block is written, so Codex uses its defaults (subagents disabled
for custom providers):

```bash
./codex/run.sh                           # latest codex, no subagents
./codex/install.sh                        # persistent config, no subagents
./codex/install.sh use                    # launch
```

When PR #29602 lands and a new Codex version ships with `namespace_tools`
support, the default path will be able to enable subagents without the
legacy downgrade. Until then, use `--subagents` with 0.132.0.

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
      "context_window": 5000000,
      "max_context_window": 5000000,
      "auto_compact_token_limit": 4500000,
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

Catalog windows default to `CODEX_CONTEXT_WINDOW=5000000`,
`CODEX_MAX_CONTEXT_WINDOW=5000000`, and
`CODEX_AUTO_COMPACT_TOKEN_LIMIT=4500000` from `coding-agents/.env` (or
`--context-window` / `--max-context-window` / `--auto-compact-token-limit` on
`install.sh` / `run.sh`).

Then set these in your `~/.codex/config.toml` (without subagents):

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

Or with subagents (requires codex@0.132.0):

```toml
model = "gw-glm-5.2"
model_provider = "subconscious"
model_catalog_json = "~/.codex/model-catalog.json"
web_search = "disabled"

[features]
multi_agent = true

[agents]
max_threads = 4
max_depth = 1
interrupt_message = true

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
| `~/.codex/config.toml` | Provider config pointing to your gateway with `wire_api = "responses"` and `web_search = "disabled"`. With `--subagents`, also includes `[features] multi_agent = true` and `[agents]` block (max 4 threads, depth 1) |
| `~/.codex/model-catalog.json` | Model metadata catalog (context window, tool support) so Codex doesn't print a "Model metadata not found" warning |
| `~/.codex/subconscious.env` | `SUBCONSCIOUS_API_KEY` + `SUBCONSCIOUS_GATEWAY_URL` (mode 600) |
| `~/.codex/hooks.json` | Registers `PreCompact` / `PostCompact` compaction reporting |
| `~/.codex/subconscious-hook.sh` | Fail-open hook script (POSTs to `/v1/agent-hooks`) |
| `~/.codex/subconscious-hooks.env` | Gateway URL + API key for the hook script (mode 600) |

## Compaction hooks

| Codex hook | Gateway event |
| --- | --- |
| `PreCompact` | `conversation_compaction` with `phase: "start"` |
| `PostCompact` | `conversation_compaction` with `phase: "end"` |

`conversation_id` is the hook `session_id` (typically the same `thr_…` value
Codex sends as `thread-id` on model requests). Matcher accepts both `manual`
and `auto` triggers. The hook never returns `continue: false`, so it cannot
block compaction.

Validate with `/compact` after trusting hooks - under TIMRUN + large catalog
windows, auto-compact rarely fires.

## Conversation correlation

The gateway detects Codex via two mechanisms (checked in order):

1. **`x-subconscious-client: codex`** — explicit override, always wins
2. **`thread-id` / `x-codex-turn-metadata` / `session-id`** — native Codex headers (heuristic fallback)

Sub-agent sessions (`x-codex-parent-thread-id`) are linked to their parent
conversation in the dashboard and are tracked as a separate conversation.
