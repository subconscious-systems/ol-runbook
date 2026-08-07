# Using Claude Code with Subconscious API Gateway

Claude Code (the `claude` CLI) talks to the gateway via the Anthropic Messages
API (`POST /v1/messages`). It reads its target origin and credentials from
environment variables, so no config file is needed — just set the env and
launch.

## How it works

Claude Code sends `x-claude-code-session-id` and `x-claude-code-agent-id`
headers natively. The gateway uses these to group requests into the dashboard
**Conversations** view automatically.

With OTEL enabled (default in `run.sh` / `install`), Claude exports
[`api_request`](https://code.claude.com/docs/en/monitoring-usage#api-request-event)
log events to the gateway's Claude Code-only `POST /v1/logs` endpoint so it can
back-fill `query_source` (main turn vs session title / compact / etc.). Requires
Claude Code **v2.1.152+**. No hooks. Traces are not exported.

| Env var | Purpose |
| --- | --- |
| `ANTHROPIC_BASE_URL` | Gateway origin (e.g. `https://gateway.example`) |
| `ANTHROPIC_AUTH_TOKEN` | Gateway API key (`sk-gw-...`) |
| `ANTHROPIC_MODEL` | Primary model name from the dashboard |
| `ANTHROPIC_SMALL_FAST_MODEL` | Model used for lightweight tasks (set to same as `ANTHROPIC_MODEL`) |
| `CLAUDE_CODE_SUBAGENT_MODEL` | Model used for spawned subagents (set to same as `ANTHROPIC_MODEL`) |
| `CLAUDE_CODE_MAX_CONCURRENT_SUBAGENTS` | Max subagents running at once (set to `4`; Claude default `20`) |
| `CLAUDE_CODE_MAX_SUBAGENT_SPAWN_DEPTH` | Max subagent nesting depth (set to `1` — nesting off; Claude default `3`) |
| `CLAUDE_CODE_AUTO_COMPACT_WINDOW` | Auto-compact window in tokens (default `1000000`). Claude Code documents a hard range of `100000`–`1000000` and clamps higher values to 1M. Docs: [env vars](https://code.claude.com/docs/en/env-vars), [set the auto-compact window](https://code.claude.com/docs/en/context-window#set-the-auto-compact-window) |
| `CLAUDE_CODE_MAX_CONTEXT_TOKENS` | Assumed context window for unrecognized / gateway model ids (default `3000000`). Applied for non-Claude model names as of Claude Code v2.1.193+; does not raise the auto-compact ceiling above 1M. Docs: [env vars](https://code.claude.com/docs/en/env-vars) |
| `CLAUDE_CODE_ENABLE_TELEMETRY` | Enable OTEL pipeline for log export |
| `OTEL_LOGS_EXPORTER` / `OTEL_EXPORTER_OTLP_*` | Export `api_request` events to `${ANTHROPIC_BASE_URL}/v1/logs` (`x-api-key`) |
| `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC` | Block Anthropic Statsig / surveys / auto-update side traffic |

Subagent traffic will be its own conversation and have a link back to the parent session.

### Token reporting and compaction

Use an API key with **TIMRUN context** reporting (the default for new keys).
TIMRUN-reported `input_tokens` stay near the retained window (typically well
under ~150k), so Claude Code's auto-compact ceiling (max **1M**) almost never
triggers - leave auto-compact **on**. Do not try to raise
`CLAUDE_CODE_AUTO_COMPACT_WINDOW` above 1M; the product clamps it.

When the HTTP request body approaches Anthropic's **32 MB** Messages API limit,
or network round-trips feel slow because the client is resending a huge message
list, run `/compact` manually (hooks cannot trigger `/compact`).

Docs: [auto-compact window](https://code.claude.com/docs/en/context-window#set-the-auto-compact-window),
[`CLAUDE_CODE_AUTO_COMPACT_WINDOW`](https://code.claude.com/docs/en/env-vars),
[`CLAUDE_CODE_MAX_CONTEXT_TOKENS`](https://code.claude.com/docs/en/env-vars),
[Messages API request size limits (32 MB)](https://platform.claude.com/docs/en/api/errors#request-size-limits).

## Shared env (preferred)

All scripts read `GATEWAY_URL`, `API_KEY` (or `CLAUDE_CODE_API_KEY`), and
optional `MODEL` from the shared `coding-agents/.env` one level up. Set that
once, then run install/run without passing credentials on the command line.
`CLAUDE_CODE_API_KEY` overrides shared `API_KEY` when set.

```bash
cd ol-runbook/coding-agents
cp env.example .env   # one-time: paste GATEWAY_URL + API_KEY
```

`--gateway-url` / `--api-key` (and related) flags still override `.env` when you
need a one-off value.

## Quick start (ephemeral — no persistent config)

`run.sh` launches Claude Code using env vars only — nothing is written to
`~/.claude/` config files.

```bash
cd ol-runbook/coding-agents
# ensure .env is filled in (see above)
./claude-code/run.sh              # uses GATEWAY_URL/API_KEY from .env
./claude-code/run.sh --continue   # pass args through to claude
./claude-code/run.sh --compact-window 1000000 --max-context-tokens 3000000 -- --continue
./claude-code/run.sh --model gw-glm-5.2 -p "hi"
```

`run.sh` accepts the same overrides as `install.sh` (`--gateway-url`,
`--api-key`, `--model`, `--compact-window`, `--max-context-tokens`). Unrecognized
args (or anything after `--`) go to `claude`.

After changing compact / context values, re-run `./claude-code/install.sh` (or
use `run.sh`) so a fresh process picks them up. A stale
`~/.claude/subconscious-gateway.env` will keep old numbers for `install.sh use`.

Or source it to just export env:

```bash
source claude-code/run.sh
```

## Install (persistent config)

```bash
cd ol-runbook/coding-agents
chmod +x claude-code/install.sh

# Reads GATEWAY_URL + API_KEY from .env; writes ~/.claude/subconscious-gateway.env (mode 600)
./claude-code/install.sh
```

`install` is the default subcommand and may be omitted.

## Launch

After install, launch claude with the gateway env loaded:

```bash
./claude-code/install.sh use                    # launches claude
./claude-code/install.sh use -- --continue      # pass args through to claude
./claude-code/install.sh use -- -p "fix the bug"
```

Or load the env into your current shell without launching:

```bash
source <(./claude-code/install.sh env)          # load   ANTHROPIC_* / CLAUDE_CODE_*
source <(./claude-code/install.sh unset)        # remove ANTHROPIC_* / CLAUDE_CODE_*
```

Check status / uninstall:

```bash
./claude-code/install.sh status
./claude-code/install.sh uninstall
```

## What gets installed

| Path | Purpose |
| --- | --- |
| `~/.claude/subconscious-gateway.env` | Gateway env exports (mode 600, not committed) |

No hooks are needed for Claude Code. Session correlation uses native
`x-claude-code-*` headers. Purpose (`query_source`) uses OTEL
[`api_request`](https://code.claude.com/docs/en/monitoring-usage#api-request-event)
logs to the Claude Code-only `/v1/logs` ingest (see env table above).

## Multiple gateways

The env file stores one gateway at a time. To switch gateways, update
`coding-agents/.env` (or pass `--gateway-url` / `--api-key` once) and re-run
`install`. Or manage multiple shell sessions by sourcing different env files
manually.
