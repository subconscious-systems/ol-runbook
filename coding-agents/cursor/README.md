# Using Cursor with Subconscious API Gateway

First go into Cursor settings and enable the "OpenAI API Key Override" setting. Follow these LiteLLM docs for a similar setup: https://docs.litellm.ai/docs/tutorials/cursor_integration

Use base url `https://<your-gateway-url>`, an API key from the Subconscious dashboard, and the configured model name from the dashboard.

# Cursor hooks — Conversations correlation

Install one local [Cursor agent hook](https://cursor.com/docs/agent/hooks) so the
dashboard can group your Cursor traffic into conversations.

Hooks **cannot** inject headers into model HTTP, which is the only reason this
exists. The flow is deliberately small:

1. On each prompt submission, the hook `POST`s `/v1/agent-hooks` with the Cursor
   `conversation_id` and the **raw prompt text**.
2. The gateway fingerprints that prompt and binds the first LLM request of the
   prompt to the conversation.
3. Every later request of the conversation binds itself, by matching the
   assistant turn its history ends with. No further hook calls are involved.

Step 3 is why one hook is enough: the gateway chains turns together server-side,
so tool loops, plan-to-build handoffs, and subagents all attach without a
lifecycle event per turn.

## Requirements

- `jq`, `curl`
- A gateway API key (same key as Cursor's OpenAI override)
- Gateway URL reachable from your machine

No SHA-256 tool is needed: the hook sends the prompt and the gateway hashes it.

## Shared env (preferred)

Prefer the shared `coding-agents/.env` one level up for `GATEWAY_URL`,
`API_KEY`, and optional `MODEL`. Set that once, then install without flags:

```bash
cd ol-runbook/coding-agents
cp env.example .env   # one-time: paste GATEWAY_URL + API_KEY
```

`--gateway-url` / `--api-key` flags still override `.env` when you need a
one-off value.

## Install

```bash
cd ol-runbook/coding-agents
chmod +x cursor/install.sh cursor/hook.sh
./cursor/install.sh    # reads GATEWAY_URL + API_KEY from .env
```

`install` is the default subcommand and may be omitted — `./install.sh` with no
subcommand runs install.

Restart Cursor fully so it reloads `~/.cursor/hooks.json`.

Check status / uninstall:

```bash
./cursor/install.sh status
./cursor/install.sh uninstall
```

Hooks install **user-wide** under `~/.cursor` only (API key stays out of git working trees).

Upgrading from an earlier release prunes the hook entries it registered for
`afterAgentResponse`, `stop`, `subagentStart`, and `subagentStop`; those events
are no longer used. `uninstall` also removes the old
`~/.cursor/subconscious-corr-state.json` state file.

## What gets installed

| Path | Purpose |
| --- | --- |
| `~/.cursor/hooks/subconscious-hook.sh` | Fail-open hook script |
| `~/.cursor/subconscious-hooks.env` | `SUBCONSCIOUS_GATEWAY_URL` + `SUBCONSCIOUS_API_KEY` (mode 600) |
| `~/.cursor/hooks.json` | Merges `beforeSubmitPrompt` only |

There is no local state file. The gateway resolves the Cursor `conversation_id`
to its own UUID on every call, so the hook never needs to cache a mapping and
ignores the response body entirely.

## Events

| Cursor hook | Gateway event |
| --- | --- |
| `beforeSubmitPrompt` | `turn_open` with `conversation_id`, `generation_id`, and raw `prompt` |

Nothing else is registered. `afterAgentThought` never fires for gateway-served
models; `afterAgentResponse` is empty in plan mode and tool-only turns;
`preToolUse` only fires for a subset of tools and rewrites `Shell` tool ids; and
`subagentStop` is unreliable for background Tasks. Correlation does not depend on
any of them.

## Fingerprint contract

The gateway normalizes then SHA-256s the prompt. The hook sends raw text, so
there is only one implementation of this and it cannot drift:

1. Replace `\r\n` with `\n`
2. Strip the last `<user_query>` / `<userRequest>` wrapper block, if present
3. Trim leading/trailing whitespace
4. SHA-256 hex (64 lowercase hex chars) → `prompt_fp`

Fixture (must match gateway unit tests):

| Input | `prompt_fp` |
| --- | --- |
| `fix` | `1c6e6c4c02e55178e85890fc9bbed4ce046415ec8122bf38f711b779184ae2a0` |
| `hello\r\nworld  ` equals `hello\nworld` after normalize | same hash |

## Plan → Build

Cursor injects a literal `Plan\n\n` prefix inside the request's `<user_query>`
block for the plan-implement handoff, so the Build prompt's fingerprint does not
match what the hook announced. Those turns still correlate, because the Build
generation's first request chains back to the Plan generation's last assistant
turn. Nothing extra is needed on the client.

## Subagents

Each Task-tool subagent gets its own conversation row, nested under the
conversation that spawned it, with no subagent hooks involved. A subagent's first
request is a fresh conversation whose only user message is the parent's `Task`
prompt verbatim, and the gateway matches that against the prompt the parent
handed down.
