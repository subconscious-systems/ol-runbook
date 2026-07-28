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

## Requirements

- VS Code installed globally (stable `Code` or `Code - Insiders`; also supports
  `VSCodium`). Auto-detected; override with `--vscode-app`.
- `jq`
- A gateway API key (create one in the Subconscious dashboard)
- Gateway URL reachable from your machine

## Install

```bash
cd ol-runbook/coding-agents/copilot
chmod +x install.sh
./install.sh --gateway-url 'https://your-gateway.example'
```

Or, reading from the shared `coding-agents/.env` (copy `env.example` to `.env`
first):

```bash
cd ol-runbook/coding-agents
./copilot/install.sh
```

`install` is the default subcommand and may be omitted — `./install.sh` with no
subcommand runs install, and `./install.sh --gateway-url URL` is equivalent to
`./install.sh` with the flag.

The API key is **not** passed on the command line. After install:

1. **Restart VS Code** (fully quit, not just reload).
2. Open Chat → model picker (gear) → **Manage Language Models**.
3. Find **Subconscious Gateway** → click the key icon to set the API key.
4. Paste your gateway API key (`sk-gw-...`).

The script writes a stable secret id (`chat.lm.secret.subconscious-gateway`) so
you only enter the key once, even if you re-run `install`.

Check status / uninstall:

```bash
./install.sh status
./install.sh uninstall
```

## Options

| Flag | Default | Purpose |
| --- | --- | --- |
| `--gateway-url URL` | (from `.env`) | Gateway origin |
| `--model MODEL` | `gw-glm-5.2` | Model id sent to the gateway |
| `--max-input-tokens N` | `200000` | Model context window input tokens |
| `--max-output-tokens N` | `16000` | Model max output tokens |
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
        "maxInputTokens": 200000,
        "maxOutputTokens": 16000,
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
VS Code **does** support [agent hooks](https://code.visualstudio.com/docs/agent-customization/language-models)
via `~/.copilot/hooks/` — a directory of JSON files that invoke shell scripts
on chat lifecycle events.

The installer writes a `subconscious-hook.json` + `subconscious-hook.sh` pair
into `~/.copilot/hooks/`. The hook script:

1. Reads the chat event (`SessionStart`, `UserPromptSubmit`, `Stop`,
   `SubagentStart`, `SubagentStop`) from stdin.
2. Extracts `session_id` and `timestamp` from the event payload.
3. Normalizes the prompt text and computes a SHA-256 fingerprint (same algorithm
   as the Cursor hook).
4. `POST /v1/agent-hooks` to your gateway with `x-subconscious-client: copilot`,
   a `turn_open`/`turn_close` event, and the prompt fingerprint.

The gateway soft-binds later `/v1/chat/completions` requests that share the
same fingerprint to group them into a **Conversation** row in the dashboard.

This is the same mechanism Cursor uses, adapted for VS Code's hook format.

### What gets installed for correlation

| Path | Purpose |
| --- | --- |
| `~/.copilot/hooks/subconscious-hook.json` | Hook registration (PascalCase event names) |
| `~/.copilot/hooks/subconscious-hook.sh` | Fail-open hook script (POSTs to `/v1/agent-hooks`) |
| `~/.copilot/subconscious-hooks.env` | `SUBCONSCIOUS_GATEWAY_URL` + `SUBCONSCIOUS_API_KEY` (mode 600) |

### Fingerprint contract

Both the hook and the gateway normalize then SHA-256:

1. Replace `\r\n` with `\n`
2. Trim leading/trailing whitespace
3. SHA-256 hex (64 lowercase hex chars) → `prompt_fp`

### Events

| VS Code hook | Gateway event |
| --- | --- |
| `SessionStart` | `turn_open` (+ `prompt_fp` from `initial_prompt` if present) |
| `UserPromptSubmit` | `turn_open` (+ `prompt_fp` from `prompt`) |
| `Stop` | `turn_close` |
| `SubagentStart` | `turn_open` (child conversation, `parent_conversation_id` set) |
| `SubagentStop` | `turn_close` (child conversation) |

Same VS Code `session_id` across multiple prompts upserts one Conversations row.
Each prompt opens a new generation window (`generation_id` = `session_id:timestamp`).

### Limitations

- No `turn_heartbeat` equivalent (VS Code has no "response received" hook).
- The hook fires on chat lifecycle events, not on raw HTTP requests, so
  correlation is heuristic (prompt fingerprint soft-bind) rather than
  header-hard-bound like Codex or Claude Code.
- If two chats start with identical prompts, they may merge into one
  conversation. This is a known limitation of the fingerprint approach.

## GitHub Copilot desktop app

The GitHub Copilot desktop app (separate product from VS Code) also supports
OpenAI-compatible BYOK providers via **Settings → Model Providers → Add
Provider**. Use base URL `https://your-gateway.example/v1` and your API key;
the model id (`gw-glm-5.2`) appears in the picker. The same correlation caveat
applies. This installer only configures VS Code, not the desktop app.
