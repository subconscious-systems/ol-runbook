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

## Quick start

```bash
cd ol-runbook/coding-agents/claude-code
chmod +x install.sh

# Write env file to ~/.claude/subconscious-gateway.env (mode 600)
./install.sh install \
  --gateway-url 'https://your-gateway.example' \
  --api-key 'sk-gw-...'

# Launch claude with the gateway env loaded
./install.sh use

# Pass arguments through to claude
./install.sh use -- --continue
./install.sh use -- -p "fix the bug"
```

## Use in your current shell

Instead of launching claude directly, you can source the env into your
current shell and run `claude` yourself:

```bash
# Load gateway env
source <(./install.sh env)

# Verify
echo $ANTHROPIC_BASE_URL

# Run claude
claude
```

## Unset env from your current shell

```bash
source <(./install.sh unset)
```

This removes all `ANTHROPIC_*` and `CLAUDE_CODE_*` variables that the
gateway setup exported.

## Check status

```bash
./install.sh status
```

## Uninstall

```bash
./install.sh uninstall
```

This removes the env file. To also clear the env from your current shell:

```bash
source <(./install.sh unset)
```

## Ephemeral runner (no persistent config)

`run.sh` launches Claude Code using env vars only — nothing is written to
`~/.claude/` config files.

```bash
cp ../env.example ../.env      # one-time setup (shared at coding-agents/ level)
./run.sh                        # uses GATEWAY_URL/API_KEY from ../.env
./run.sh --continue              # pass args through to claude
```

Or source it to just export env:

```bash
source run.sh
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
