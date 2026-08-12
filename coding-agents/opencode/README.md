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

The scripts do not set model `limit.context` or `limit.output`, so this
integration does not impose a client-side request-size threshold. OpenCode's
own defaults and user configuration determine when it compacts.

### Token reporting and compaction

Use an API key with **Full list context** reporting (edit the key in the
dashboard if it still says TIMRUN - new keys default to TIMRUN). Full-list
`input_tokens` grow with the client message list so OpenCode can account for
real payload growth.

Docs: [Compaction](https://opencode.ai/v2/docs/compaction),
[Config / compaction](https://opencode.ai/docs/config/).

### Compaction reporting

`install.sh` also installs a plugin that tells the gateway when a session
compacts. This matters because OpenCode summarizes by issuing an ordinary
completion through the configured provider: without the plugin, the gateway sees
the summarization as the largest main-thread turn of the conversation, which
inflates peak context and the traditional comparison.

The plugin uses two OpenCode callbacks:

| Callback | Reported phase |
| --- | --- |
| `experimental.session.compacting` | `start`, before the summary is generated |
| `session.compacted` event | `end`, after it completes |

Requests between the two are recorded as the compaction itself. The dashboard
then restarts the context profile at the following turn while keeping cumulative
pruned tokens and token savings for the whole conversation.

The plugin never modifies your compaction prompt, and fails open: if the gateway
is unreachable it gives up after 2 seconds and the session continues. If a
signal is lost the conversation still works, it just keeps the pre-compaction
context profile.

Docs: [Plugins](https://opencode.ai/docs/plugins/).

With OpenCode, subagent traffic will be its own conversation and have a link back to the parent session.

## Requirements

- `jq`
- A gateway API key (create one in the Subconscious dashboard)
- Gateway URL reachable from your machine

## Shared env (preferred)

All scripts read `GATEWAY_URL`, `API_KEY` (or `OPENCODE_API_KEY`), and optional
`MODEL` from the shared `coding-agents/.env` one level up. Set that once, then
run install/run without passing credentials on the command line. Prefer a
**Full list** key via `OPENCODE_API_KEY` when `API_KEY` is TIMRUN for other agents.

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

This integration intentionally leaves model context and output limits unset.
Configure them directly in OpenCode if you want client-side request budgeting.

Export the API key:

```sh
export SUBCONSCIOUS_API_KEY="sk-gw-..."
```

## What gets installed

| Path | Purpose |
| --- | --- |
| `~/.opencode/opencode.json` | Provider config pointing to your gateway with `x-subconscious-client` |
| `~/.opencode/subconscious.env` | `SUBCONSCIOUS_API_KEY` + `SUBCONSCIOUS_GATEWAY_URL` env vars (mode 600) |
| `~/.config/opencode/plugins/subconscious-compaction.ts` | Reports compaction start/end so context accounting restarts at the right turn |

## Conversation correlation

The gateway detects OpenCode via two mechanisms (checked in order):

1. **`x-subconscious-client: opencode`** — explicit override, always wins
2. **`x-session-affinity` + `x-session-id`** — native OpenCode headers (heuristic fallback)

Sub-agent sessions (`x-parent-session-id`) are linked to their parent
conversation in the dashboard.
