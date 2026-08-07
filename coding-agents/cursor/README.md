# Using Cursor with Subconscious API Gateway

First go into Cursor settings and enable the "OpenAI API Key Override" setting. Follow these LiteLLM docs for a similar setup: https://docs.litellm.ai/docs/tutorials/cursor_integration

Use base url `https://<your-gateway-url>`, an API key from the Subconscious dashboard, and the configured model name from the dashboard.

### Token reporting and compaction

Use an API key with **TIMRUN context** reporting (the default for new keys).
TIMRUN-reported `input_tokens` stay near the retained window (typically well
under ~150k), so Cursor's assumed compaction budget almost never fires.

Cursor does **not** expose a setting for custom OpenAI-compatible model
context windows. Uncataloged custom / base URL models currently default to a
**1M** assumed window (staff: by design; no auto-detect and no BYOK context UI):

- [Custom models set the context window to 1M](https://forum.cursor.com/t/custom-models-set-the-context-window-to-1m/160106)
- [Custom OpenAI-compatible model shows 200K for GLM-5.2](https://forum.cursor.com/t/custom-openai-compatible-model-shows-200k-context-limit-for-glm-5-2-even-though-it-supports-1m-context/163360)
- Feature request cited from those threads: **Unlock Full Context Window with Own API Keys**

If request bodies grow too large (gateway **50 MiB**) or round-trips feel slow,
use `/summarize` manually. When a compaction does happen, the `preCompact` hook
below tells the gateway so the dashboard restarts the context profile at the
right turn.

# Cursor hooks — Conversations correlation

Install two local [Cursor hooks](https://cursor.com/docs/hooks) so the dashboard
can group your Cursor traffic into conversations and know when the context was
compacted.

Hooks **cannot** inject headers into model HTTP, which is the only reason this
exists. The flow is deliberately small:

1. On each prompt submission, the hook `POST`s `/v1/agent-hooks` with the Cursor
   `conversation_id` and the **raw prompt text**.
2. The gateway fingerprints that prompt and binds the first LLM request of the
   prompt to the conversation.
3. Every later request of the conversation binds itself, by matching the
   assistant turn its history ends with. No further hook calls are involved.

Step 3 is why one hook covers correlation: the gateway chains turns together
server-side, so tool loops, plan-to-build handoffs, and subagents all attach
without a lifecycle event per turn.

## Requirements

- `jq`, `curl`
- A gateway API key (same key as Cursor's OpenAI override)
- Gateway URL reachable from your machine

No SHA-256 tool is needed: the hook sends the prompt and the gateway hashes it.

## Shared env (preferred)

Prefer the shared `coding-agents/.env` one level up for `GATEWAY_URL`,
`API_KEY` (or `CURSOR_API_KEY`), and optional `MODEL`. Set that once, then
install without flags. `CURSOR_API_KEY` overrides shared `API_KEY` when set.

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

## What gets installed

| Path | Purpose |
| --- | --- |
| `~/.cursor/hooks/subconscious-hook.sh` | Fail-open hook script |
| `~/.cursor/subconscious-hooks.env` | `SUBCONSCIOUS_GATEWAY_URL` + `SUBCONSCIOUS_API_KEY` (mode 600) |
| `~/.cursor/hooks.json` | Merges `beforeSubmitPrompt` and `preCompact` |

There is no local state file. The gateway resolves the Cursor `conversation_id`
to its own UUID on every call, so the hook never needs to cache a mapping and
ignores the response body entirely.

## Events

| Cursor hook | Gateway event |
| --- | --- |
| `beforeSubmitPrompt` | `conversation_ensure` with `conversation_id` and raw `prompt` |
| `preCompact` | `conversation_compaction` with `phase: point` |

Nothing else is registered. `afterAgentThought` never fires for gateway-served
models; `afterAgentResponse` is empty in plan mode and tool-only turns;
`preToolUse` only fires for a subset of tools and rewrites `Shell` tool ids; and
`subagentStop` is unreliable for background Tasks. Correlation does not depend on
any of them.

Both registered hooks are conversation-lifecycle hooks, which also sidesteps a
known Cursor bug: after a mid-turn compaction, **tool-execution** hooks emit an
empty `conversation_id` until the next user prompt. Lifecycle hooks keep the
correct id.

## Compaction

Cursor's `preCompact` is observational: it cannot block or modify compaction, and
Cursor has no `postCompact`. So the hook reports a zero-width `point`, and the
gateway places the context boundary on the first following turn whose retained
context actually shrinks.

Closing a window at the next `beforeSubmitPrompt` instead would be wrong: Cursor
compacts **mid-turn** and keeps working without a new user prompt, so that window
would misclassify real turns as part of the compaction.

The hook forwards Cursor's own view of the context (`context_tokens`,
`context_window_size`, `trigger`, `is_first_compaction`) as metadata, which is
useful for comparing the client's numbers against the gateway's at the same
boundary.

After a compaction the dashboard restarts the context profile while keeping
cumulative pruned tokens and token savings for the whole conversation.

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
