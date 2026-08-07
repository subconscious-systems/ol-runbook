# Coding Agents

Point your coding agents at the Subconscious API Gateway. Use the **`mbta`** CLI (preferred) or the per-agent `install.sh` / `run.sh` scripts. All of them read gateway settings from a shared env file (default profile: `.env`).

## Quick start

```bash
cd ol-runbook

# Optional: put mbta on your PATH (symlink → this clone)
./mbta self-install
# If needed: export PATH="$HOME/.local/bin:$PATH"

# One-time: set gateway settings (writes coding-agents/.env)
mbta config --gateway-url https://gateway.example --api-key sk-gw-... --model gw-glm-5.2

# Install / run agents
mbta cursor install
mbta claude-code run
mbta codex run
mbta opencode run
mbta pi install
mbta copilot install   # VS Code: paste API key in the UI after install
```

Without installing on PATH, invoke as `./mbta …` from `ol-runbook/`.

### Profiles

`default` lives at `coding-agents/.env`. Named profiles live under `coding-agents/profiles/<name>.env`:

```bash
mbta config --profile staging --gateway-url https://staging.example --api-key sk-gw-...
mbta --profile staging cursor install
mbta -p staging claude-code run
mbta config list
```

You can also set `MBTA_PROFILE=staging`. Direct `./cursor/install.sh` always uses the default `.env` unless `MBTA_ENV_FILE` is set.

### Equivalent without `mbta`

```bash
cd ol-runbook/coding-agents
cp env.example .env   # paste GATEWAY_URL + API_KEY
./cursor/install.sh
./claude-code/run.sh
./codex/run.sh
./opencode/run.sh
./pi/install.sh
./copilot/install.sh
```

## Shared env file

Shared credentials apply to every agent. Optional per-agent `*_API_KEY` overrides let you keep a TIMRUN key in `API_KEY` and a Full list key on OpenCode / Pi / Copilot without re-editing `.env` when you switch agents. Context / compaction knobs are **per-agent prefixed names** (no shared `CONTEXT_LIMIT`).

| Variable | Purpose |
| --- | --- |
| `GATEWAY_URL` | Gateway origin (e.g. `https://gateway.example.com`) |
| `API_KEY` | Shared gateway API key (`sk-gw-...`); prefer TIMRUN for Claude/Codex/Cursor |
| `OPENCODE_API_KEY` / `CLAUDE_CODE_API_KEY` / `CODEX_API_KEY` / `PI_API_KEY` / `COPILOT_API_KEY` / `CURSOR_API_KEY` | Optional per-agent key override (falls back to `API_KEY`) |
| `MODEL` | Model name (default: `gw-glm-5.2`) |
| `CLAUDE_GATEWAY_URL` | Optional Claude-only origin override |
| `OPENCODE_CONTEXT_LIMIT` / `OPENCODE_OUTPUT_LIMIT` | OpenCode `limit.context` / `limit.output` |
| `CLAUDE_CODE_AUTO_COMPACT_WINDOW` / `CLAUDE_CODE_MAX_CONTEXT_TOKENS` | Claude Code compact (max 1M) / assumed window |
| `CODEX_CONTEXT_WINDOW` / `CODEX_MAX_CONTEXT_WINDOW` / `CODEX_AUTO_COMPACT_TOKEN_LIMIT` | Codex model catalog |
| `PI_CONTEXT_WINDOW` / `PI_MAX_TOKENS` | Pi `models.json` |
| `COPILOT_MAX_INPUT_TOKENS` / `COPILOT_MAX_OUTPUT_TOKENS` | VS Code Copilot Custom Endpoint |
| (Cursor) | None - product assumes ~1M for custom models |

Precedence for credentials: **CLI `--api-key`** > **agent `*_API_KEY`** > **shared `API_KEY`**.
Precedence for other agent settings: **CLI flags** > **agent-prefixed `.env` vars** > **script defaults**.

### Dual keys / switching agents

Create two dashboard keys with different Client context reporting settings:

1. **TIMRUN** - put in `API_KEY` (and/or Claude/Codex/Cursor overrides).
2. **Full list** - put in `OPENCODE_API_KEY`, `PI_API_KEY`, and `COPILOT_API_KEY` (hooks; Copilot Chat still enters the key in the VS Code UI).

Each agent then picks the right reporting mode without changing the shared default.

## Token reporting and compaction

API keys have a **Client context reporting** setting on the dashboard that controls which `usage.input_tokens` value coding agents see:

| Mode | What the client sees | Typical use |
| --- | --- | --- |
| **TIMRUN context** (new-key default) | Retained prompt size (+ cache when available) after GPU-level compression | Claude Code, Codex, Cursor |
| **Full list context** | Tokenized full message-list size for the turn | OpenCode, Pi, Copilot |

TIMRUN can compress context on the GPU so a conversation can run for a long time without the *server-side* retained window growing without bound. Clients still resend large message lists over the network. Harness auto-compaction budgets off the `input_tokens` the gateway returns, so reporting mode and IDE/CLI compaction interact:

- With **full list** reporting, `input_tokens` track the growing client payload. Agents that let you configure a large context window (OpenCode, Pi, Copilot) should use full-list reporting and rely on their auto-compaction knobs.
- With **TIMRUN** reporting, `input_tokens` stay near the retained window (typically well under ~150k). Harnesses that hard-cap auto-compact around 1M (Claude Code, Cursor) almost never auto-compact. For Claude Code / Codex, use manual `/compact` when request bodies get too large or round-trips feel slow. For **Cursor** with OpenAI API Key Override, `/summarize` does not use the custom base URL ([Cursor forum](https://forum.cursor.com/t/unable-to-automatically-summarize-the-summarization-feature-cannot-specify-a-model/156959/9)) - start a new chat instead.

New keys default to **TIMRUN context**. For OpenCode / Pi / Copilot, edit the key (or create a second key) and set **Full list context**. Per-agent recommendations and upstream docs live in each agent README linked below.

### Context / compaction defaults

Token windows are sized to stay under the **HTTP request-body** limit that actually binds the agent, not an arbitrary model context number.

| Agent | Recommended reporting | `.env` knobs | Default | Binding transfer limit | Notes |
| --- | --- | --- | --- | --- | --- |
| **OpenCode** | Full list | `OPENCODE_CONTEXT_LIMIT` / `OPENCODE_OUTPUT_LIMIT` | `5000000` / `65536` | Gateway **50 MiB** | Configurable auto-compaction via `limit.context` |
| **Pi** | Full list | `PI_CONTEXT_WINDOW` / `PI_MAX_TOKENS` | `5000000` / `65536` | Gateway **50 MiB** | Same pattern as OpenCode |
| **Copilot** | Full list | `COPILOT_MAX_INPUT_TOKENS` / `COPILOT_MAX_OUTPUT_TOKENS` | `5000000` / `65536` | Gateway **50 MiB** | VS Code Custom Endpoint budgeting |
| **Claude Code** | TIMRUN | `CLAUDE_CODE_AUTO_COMPACT_WINDOW` / `CLAUDE_CODE_MAX_CONTEXT_TOKENS` | `1000000` / `3000000` | Anthropic Messages API **32 MB** | Auto-compact capped at 1M; under TIMRUN it rarely fires - leave on; manual `/compact` for payload/latency |
| **Codex** | TIMRUN | `CODEX_CONTEXT_WINDOW` / `CODEX_AUTO_COMPACT_TOKEN_LIMIT` | `5000000` / `4500000` | Gateway **50 MiB** | Same TIMRUN pattern as Claude Code |
| **Cursor** | TIMRUN | (none) | ~`1000000` assumed | Gateway **50 MiB** | No custom-model context UI; ~1M hardcoded for base URL overrides; `/summarize` broken under override - start a new chat when requests get large |

Prefer `mbta config` (or editing `.env`) over passing credentials on the command line. `install.sh` / `run.sh` flags override the env file for a one-off.

## CLI reference (`mbta`)

```text
mbta self-install [--bin-dir DIR]
mbta self-uninstall
mbta config [--profile NAME] --gateway-url URL --api-key KEY [--model MODEL]
mbta config show|path|list
mbta config delete --profile NAME
mbta [--profile NAME] <agent> install|status|uninstall|run …
```

Agents: `cursor`, `copilot` (`vscode`), `claude-code` (`claude`), `codex`, `opencode`, `pi`.

Platform / bootstrap commands are not on this CLI yet.

## Which agent do I use?

| Agent | API surface | Correlation method | Persistent install | Ephemeral runner |
| --- | --- | --- | --- | --- |
| **[Cursor](cursor/)** | `POST /v1/chat/completions` | Hook script + prompt fingerprint soft-bind | `mbta cursor install` | - (see `mbta cursor run`) |
| **[Claude Code](claude-code/)** | `POST /v1/messages` | Native `x-claude-code-session-id` headers | `mbta claude-code install` | `mbta claude-code run` |
| **[Codex](codex/)** | `POST /v1/responses` | Native `thread-id` / session metadata | `mbta codex install` | `mbta codex run` |
| **[OpenCode](opencode/)** | `POST /v1/chat/completions` | Native `x-session-affinity` / `x-session-id` | `mbta opencode install` | `mbta opencode run` |
| **[Pi](pi/)** | `POST /v1/chat/completions` | `x-session-id` / `x-session-affinity` (compat flags) | `mbta pi install` | - |
| **[Copilot (VS Code)](copilot/)** | `POST /v1/chat/completions` | Hook script + prompt fingerprint soft-bind | `mbta copilot install` | - |
