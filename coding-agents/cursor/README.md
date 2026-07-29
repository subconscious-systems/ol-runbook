# Using Cursor with Subconscious API Gateway

First go into Cursor settings and enable the "OpenAI API Key Override" setting. Follow these LiteLLM docs for a similar setup: https://docs.litellm.ai/docs/tutorials/cursor_integration

Use base url `https://<your-gateway-url>`, an API key from the Subconscious dashboard, and the configured model name from the dashboard.

# Cursor hooks — Conversations correlation

Install local [Cursor agent hooks](https://cursor.com/docs/agent/hooks) that ensure a dashboard conversation and associate later LLM requests after the fact.

Hooks **cannot** inject headers into model HTTP. They:

1. `POST /v1/agent-hooks` with `conversation_ensure` → gateway returns a conversation UUID stored locally
2. Model traffic may land uncorrelated (with a `prompt_fp` derived from the last user message)
3. `afterAgentResponse` / `stop` → `conversation_associate` patches recent inflight rows by `prompt_fp`


## Requirements

- `jq`, `curl`
- `openssl` or `shasum` (SHA-256)
- A gateway API key (same key as Cursor's OpenAI override)
- Gateway URL reachable from your machine

## Install

```bash
cd ol-runbook/coding-agents/cursor
chmod +x install.sh hook.sh
./install.sh \
  --gateway-url 'https://your-gateway.example' \
  --api-key 'sk-...'
```

`install` is the default subcommand and may be omitted — `./install.sh` with no
subcommand runs install.

Restart Cursor fully so it reloads `~/.cursor/hooks.json`.

Check status / uninstall:

```bash
./install.sh status
./install.sh uninstall
```

Hooks install **user-wide** under `~/.cursor` only (API key stays out of git working trees).

## What gets installed

| Path | Purpose |
| --- | --- |
| `~/.cursor/hooks/subconscious-hook.sh` | Fail-open hook script |
| `~/.cursor/subconscious-hooks.env` | `SUBCONSCIOUS_GATEWAY_URL` + `SUBCONSCIOUS_API_KEY` (mode 600) |
| `~/.cursor/hooks.json` | Merges `beforeSubmitPrompt`, `afterAgentResponse`, `stop`, `subagentStart`, `subagentStop` |
| `~/.cursor/subconscious-corr-state.json` | Local ensure/associate state (created on first hook fire) |

Override state path with `SUBCONSCIOUS_CORR_STATE` (useful for tests).

## Fingerprint contract

Both the hook and the gateway normalize then SHA-256:

1. Replace `\r\n` with `\n` (hook strips `\r`)
2. Trim leading/trailing whitespace
3. SHA-256 hex (64 lowercase hex chars) → `prompt_fp`

Fixture (must match gateway unit tests):

| Input | `prompt_fp` |
| --- | --- |
| `fix` | `1c6e6c4c02e55178e85890fc9bbed4ce046415ec8122bf38f711b779184ae2a0` |
| `hello\r\nworld  ` equals `hello\nworld` after normalize | same hash |

## Events

| Cursor hook | Gateway event |
| --- | --- |
| `beforeSubmitPrompt` | `conversation_ensure` (parent: store gateway UUID + `last_prompt_fp`; subagent: pop pending queue, ensure child with `task_fp`=hash of actual prompt) |
| `afterAgentResponse` | `conversation_associate` (parent gateway UUID + `prompt_fp`) |
| `stop` | `conversation_associate` (safety net for parent + any remaining children) |
| `subagentStart` | Push `subagent_id` onto parent's pending queue (no gateway call) |
| `subagentStop` | `conversation_associate` (child UUID + `task_fp` = actual prompt hash) |

### Plan → Build

Build often skips `beforeSubmitPrompt`. If `afterAgentResponse` / `stop` still fire with the same Cursor `conversation_id`, the local state file already has the gateway UUID from the Plan turn and associate patches Build requests by `prompt_fp`.

### Subagents (SubagentStart → UPS drain)

Each Task-tool subagent gets its own conversation row. Correlation uses a
pending-subagent queue that pairs each `subagentStart` with the next
`beforeSubmitPrompt`:

1. `subagentStart` pushes `subagent_id` onto `pending_subagent_ids` on the parent.
2. The next `beforeSubmitPrompt` pops the first pending id and calls
   `conversation_ensure` with the subagent's id as grouping key.
3. The `task_fp` is `sha256(prompt)` — the hash of the **actual prompt content**
   from `beforeSubmitPrompt`, which matches the gateway's `prompt_fp` on the
   inflight record. This is NOT the short task description.
4. `subagentStop` calls `conversation_associate` using the stored `task_fp`.

Parallel siblings each get their own queue entry and prompt-hash, so they stay
distinct. The state file is serialized via a portable `mkdir` lock.

### TTL-based state cleanup

Every state-file write prunes conversation entries with `updated_at` older than
1 hour. This keeps the file bounded to active conversations only.
