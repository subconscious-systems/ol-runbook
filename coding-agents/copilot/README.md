# Using GitHub Copilot in VS Code with Subconscious API Gateway

Route GitHub Copilot Chat in VS Code through your Subconscious API Gateway. VS
Code's **Custom Endpoint** provider (`vendor: "customendpoint"`) speaks the
OpenAI Chat Completions API, which the gateway serves at `/v1/chat/completions`.

## How it works

The installer writes a `Subconscious Gateway` provider entry into VS Code's
user-wide `chatLanguageModels.json`, with the `apiKey` set to a stable
`${input:chat.lm.secret.subconscious-gateway}` reference. VS Code requires the
key to be stored in its OS-level secret store — a plaintext key in the JSON is
silently dropped ([microsoft/vscode#322299](https://github.com/microsoft/vscode/issues/322299)).

After running the installer and restarting VS Code, you enter the API key once
through the VS Code UI (Manage Language Models → key icon). The stable secret
id means you only do this once, even if you re-run the installer.

A static `x-subconscious-client: copilot` header is attached per-model via the
`requestHeaders` field so the gateway can identify the traffic source.

### Token reporting and compaction

Use an API key with **Full list context** reporting (edit the key in the
dashboard if it still says TIMRUN - new keys default to TIMRUN). The installer
sets Custom Endpoint `maxInputTokens` / `maxOutputTokens` (defaults
`5000000` / `65536`) so VS Code budgets context against the growing full-list
usage.

Copilot compaction is an LLM request through the Custom Endpoint (your
gateway). The hooks below report auto-compactions so the dashboard can restart
the context profile and bill the summarization turn as compaction rather than
as a normal main-thread turn.

Docs: [VS Code AI language models](https://code.visualstudio.com/docs/agent-customization/language-models)
(`maxInputTokens`, `maxOutputTokens`, `contextWindow`),
[PreCompact hook](https://code.visualstudio.com/docs/agents/reference/hooks-reference#precompact).

## Requirements

- VS Code installed globally (stable `Code` or `Code - Insiders`; also supports
  `VSCodium`). Auto-detected; override with `--vscode-app`.
- `jq`
- A gateway API key (create one in the Subconscious dashboard)
- Gateway URL reachable from your machine

## Shared env (preferred)

Prefer the shared `coding-agents/.env` one level up for `GATEWAY_URL` (and
optional `MODEL`). Set that once, then install without flags:

```bash
cd ol-runbook/coding-agents
cp env.example .env   # one-time: paste GATEWAY_URL (+ optional MODEL)
```

`--gateway-url` and related flags still override `.env` when you need a
one-off value. The Chat Completions API key is never taken from `.env` for
Copilot — VS Code requires it via the UI secret store (see below). Hooks use
`COPILOT_API_KEY` when set, otherwise shared `API_KEY` (prefer a Full list key).

## Install

```bash
cd ol-runbook/coding-agents
chmod +x copilot/install.sh
./copilot/install.sh    # reads GATEWAY_URL from .env
```

`install` is the default subcommand and may be omitted.

The API key is **not** passed on the command line. After install:

1. **Restart VS Code** (fully quit, not just reload).
2. Open Chat → model picker (gear) → **Manage Language Models**.
3. Find **Subconscious Gateway** → click the key icon to set the API key.
4. Paste your gateway API key (`sk-gw-...`).

The script writes a stable secret id (`chat.lm.secret.subconscious-gateway`) so
you only enter the key once, even if you re-run `install`.

Check status / uninstall:

```bash
./copilot/install.sh status
./copilot/install.sh uninstall
```

## Options

| Flag | Default | Purpose |
| --- | --- | --- |
| `--gateway-url URL` | (from `.env`) | Gateway origin |
| `--model MODEL` | `gw-glm-5.2` | Model id sent to the gateway |
| `--max-input-tokens N` | `5000000` | Model context window input tokens (drives Copilot context budgeting) |
| `--max-output-tokens N` | `65536` | Model max output tokens |
| `--vscode-app APP` | auto | `Code`, `Code - Insiders`, or `VSCodium` |

## What gets installed

| Path | Purpose |
| --- | --- |
| `~/Library/Application Support/Code/User/chatLanguageModels.json` (macOS) | Custom Endpoint provider entry with `${input:...}` key reference. Linux: `~/.config/Code/User/`; Windows: `%APPDATA%\Code\User\` |

The installer strips any prior `Subconscious Gateway` entry before writing, so
re-running `install` updates in place and preserves other providers.

## Manual setup

If you prefer to configure VS Code entirely by hand:

1. Open the model picker in Chat → **Manage Language Models** (gear) →
   **Add Models** → **Custom Endpoint**.
2. Enter a name (`Subconscious Gateway`) and your API key.
3. Select **Chat Completions** as the API type.
4. VS Code opens `chatLanguageModels.json`. Add this entry and save:

```json
[
  {
    "name": "Subconscious Gateway",
    "vendor": "customendpoint",
    "apiKey": "${input:chat.lm.secret.subconscious-gateway}",
    "apiType": "chat-completions",
    "models": [
      {
        "id": "gw-glm-5.2",
        "name": "Subconscious GLM 5.2",
        "url": "https://your-gateway.example/v1/chat/completions",
        "toolCalling": true,
        "vision": false,
        "maxInputTokens": 5000000,
        "maxOutputTokens": 65536,
        "streaming": true,
        "requestHeaders": { "x-subconscious-client": "copilot" }
      }
    ]
  }
]
```

5. Restart VS Code and select the model from the picker.

## Conversation correlation — hooks

Copilot in VS Code has no native session headers and VS Code's Custom Endpoint
provider exposes no per-request hook surface for injecting headers. However,
VS Code **does** support [agent hooks](https://code.visualstudio.com/docs/copilot/customization/hooks)
via `~/.copilot/hooks/` — a directory of JSON files that invoke shell scripts
on chat lifecycle events.

The installer writes a `subconscious-hooks.json` + `subconscious-hook.sh` pair
into `~/.copilot/hooks/`. Two lifecycle events are registered:

| VS Code hook | Gateway event |
| --- | --- |
| `UserPromptSubmit` | `conversation_ensure` with `conversation_id` (the VS Code `session_id`) and the raw `prompt`. If a pending auto-compact marker exists for that session, also `conversation_compaction` with `phase: "end"`. |
| `PreCompact` | `conversation_compaction` with `phase: "start"`, then writes a per-session pending marker under `~/.copilot/subconscious-compact-pending/` |

There is no `PostCompact` in VS Code. Auto-compaction is an LLM turn through
the gateway, so `PreCompact` opens a window and the **next** `UserPromptSubmit`
closes it. That brackets the summarization request between the two signals.

**Manual compact gap:** `PreCompact` does **not** fire after a manual compact
in current VS Code. Manual compact will not open an agent-compaction epoch in
the dashboard. Auto-compact remains the covered path.

The gateway fingerprints the prompt itself, binds the first LLM request of that
prompt, and chains every later turn of the conversation onto it — so the ensure
path does no hashing. The only local state is the short-lived pending marker
used to close a compaction window.

**Subagent fan-out** needs no hooks at all. `UserPromptSubmit` fires for each
subagent's prompt too, and the parent's `runSubagent` tool call carries that same
prompt as a top-level argument, so the gateway nests the child from the model
traffic alone. `SubagentStart` / `SubagentStop` are not registered.

### What gets installed for correlation

| Path | Purpose |
| --- | --- |
| `~/.copilot/hooks/subconscious-hooks.json` | Hook registration (PascalCase event names: `UserPromptSubmit`, `PreCompact`) |
| `~/.copilot/hooks/subconscious-hook.sh` | Fail-open hook script (POSTs to `/v1/agent-hooks`) |
| `~/.copilot/subconscious-hooks.env` | `SUBCONSCIOUS_GATEWAY_URL` + `SUBCONSCIOUS_API_KEY` (mode 600) |
| `~/.copilot/subconscious-compact-pending/` | Short-lived per-session markers so the next prompt can close an auto-compact window |

### Fingerprint contract

The hook sends raw prompt text; only the gateway hashes. It normalizes by
replacing `\r\n` with `\n`, stripping the `<userRequest>` wrapper VS Code adds
before the prompt reaches the model, trimming, then SHA-256. Keeping that in one
place is the point: when the hook hashed too, any drift between the shell and
Rust implementations broke correlation silently.

### Limitations

- The hook races the request it announces. Losing that race is recovered on the
  gateway side, which sweeps for unbound turns carrying the announced
  fingerprint — except when two sessions send byte-identical prompts, where it
  declines to guess and leaves both for the next prompt to re-anchor.
- A missed `UserPromptSubmit` costs one generation; the next prompt re-anchors
  and the chain carries the rest.

## GitHub Copilot desktop app

The GitHub Copilot desktop app (separate product from VS Code) also supports
OpenAI-compatible BYOK providers via **Settings → Model Providers → Add
Provider**. Use base URL `https://your-gateway.example/v1` and your API key;
the model id (`gw-glm-5.2`) appears in the picker. The same correlation caveat
applies. This installer only configures VS Code, not the desktop app.
