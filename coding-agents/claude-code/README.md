# Using Claude Code with Subconscious API Gateway

Claude Code (the `claude` CLI) talks to the gateway via the Anthropic Messages
API (`POST /v1/messages`). It reads its target origin and credentials from
environment variables, so no config file is needed — just set the env and
launch.

## How it works

Claude Code sends `x-claude-code-session-id` and `x-claude-code-agent-id`
headers natively. The gateway uses these to group requests into the dashboard
**Conversations** view automatically — no hooks or extra setup required for
correlation.

| Env var | Purpose |
| --- | --- |
| `ANTHROPIC_BASE_URL` | Gateway origin (e.g. `https://gateway.example`) |
| `ANTHROPIC_AUTH_TOKEN` | Gateway API key (`sk-gw-...`) |
| `ANTHROPIC_MODEL` | Primary model name from the dashboard |
| `ANTHROPIC_SMALL_FAST_MODEL` | Model used for lightweight tasks (set to same as `ANTHROPIC_MODEL`) |
| `CLAUDE_CODE_AUTO_COMPACT_WINDOW` | Context window for auto-compaction (default `150000`) |

## Shared env (preferred)

All scripts read `GATEWAY_URL`, `API_KEY`, and optional `MODEL` from the shared
`coding-agents/.env` one level up. Set that once, then run install/run without
passing credentials on the command line:

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
```

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
| `~/.claude/subconscious-gateway.env` | `ANTHROPIC_*` + `CLAUDE_CODE_*` exports (mode 600, not committed) |

No hooks are needed for Claude Code — session correlation is automatic via
native `x-claude-code-*` headers.

## Multiple gateways

The env file stores one gateway at a time. To switch gateways, update
`coding-agents/.env` (or pass `--gateway-url` / `--api-key` once) and re-run
`install`. Or manage multiple shell sessions by sourcing different env files
manually.
