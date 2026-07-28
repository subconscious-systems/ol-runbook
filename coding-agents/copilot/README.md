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
./install.sh install --gateway-url 'https://your-gateway.example'
```

Or, reading from the shared `coding-agents/.env` (copy `env.example` to `.env`
first):

```bash
cd ol-runbook/coding-agents
./copilot/install.sh install
```

`install` is the default subcommand and may be omitted — `./install.sh` with no
subcommand runs install, and `./install.sh --gateway-url URL` is equivalent to
`./install.sh install --gateway-url URL`.

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

## Conversation correlation: not available

Unlike Claude Code, Codex, OpenCode, and Pi, Copilot in VS Code has **no native
session headers** and VS Code's Custom Endpoint provider exposes no per-request
hook surface (unlike Cursor's `~/.cursor/hooks.json`). The gateway therefore
cannot group Copilot requests into the dashboard **Conversations** view.

What you do get:
- Requests are **metered** (counted toward usage/billing).
- Requests are **traced** (visible in logs / individual request inspection).
- The `x-subconscious-client: copilot` header tags the traffic source.

What you don't get:
- Per-conversation grouping in the **Conversations** dashboard view.

If conversation grouping is a hard requirement for Copilot traffic, the path
forward is a small VS Code extension that injects a per-session
`x-subconscious-trace-id` header into model HTTP requests. That is a separate,
larger piece of work — file an issue if you need it.

## GitHub Copilot desktop app

The GitHub Copilot desktop app (separate product from VS Code) also supports
OpenAI-compatible BYOK providers via **Settings → Model Providers → Add
Provider**. Use base URL `https://your-gateway.example/v1` and your API key;
the model id (`gw-glm-5.2`) appears in the picker. The same correlation caveat
applies. This installer only configures VS Code, not the desktop app.
