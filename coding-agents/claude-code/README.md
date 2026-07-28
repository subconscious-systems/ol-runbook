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

## Quick start (ephemeral — no persistent config)

`run.sh` launches Claude Code using env vars only — nothing is written to
`~/.claude/` config files.

```bash
cd ol-runbook/coding-agents/claude-code
cp ../env.example ../.env      # one-time setup (shared at coding-agents/ level)
./run.sh                        # uses GATEWAY_URL/API_KEY from ../.env
./run.sh --continue              # pass args through to claude
```

Or source it to just export env:

```bash
source run.sh
```

## Install (persistent config)

```bash
cd ol-runbook/coding-agents/claude-code
chmod +x install.sh

# Write env file to ~/.claude/subconscious-gateway.env (mode 600)
./install.sh install \
  --gateway-url 'https://your-gateway.example' \
  --api-key 'sk-gw-...'
```

## Launch

After install, launch claude with the gateway env loaded:

```bash
./install.sh use                    # launches claude
./install.sh use -- --continue      # pass args through to claude
./install.sh use -- -p "fix the bug"
```

Or load the env into your current shell without launching:

```bash
source <(./install.sh env)          # load   ANTHROPIC_* / CLAUDE_CODE_*
source <(./install.sh unset)        # remove ANTHROPIC_* / CLAUDE_CODE_*
```

Check status / uninstall:

```bash
./install.sh status
./install.sh uninstall
```

## What gets installed

| Path | Purpose |
| --- | --- |
| `~/.claude/subconscious-gateway.env` | `ANTHROPIC_*` + `CLAUDE_CODE_*` exports (mode 600, not committed) |

No hooks are needed for Claude Code — session correlation is automatic via
native `x-claude-code-*` headers.

## Multiple gateways

The env file stores one gateway at a time. To switch gateways, re-run
`install` with a different `--gateway-url` and `--api-key`. Or manage
multiple shell sessions by sourcing different env files manually.
