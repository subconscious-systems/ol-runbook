# Coding agents

Point Claude Code, Codex, OpenCode, Cursor, Copilot, and Pi at your Subconscious Inference System gateway with **subconscious-cli** (`subc`).

## Quick start

Install the CLI, point it at the origin and API key from your dashboard, then launch an agent:

```bash
npm install -g subconscious-cli

subc config --gateway-url https://gateway.example --api-key sk-gw-... --model gw-glm-5.2

subc claude
```

Use the model name shown in your dashboard or `GET /v1/models/available` (the models this API key may call). `GET /v1/models` is the public fleet catalog. `subc <agent> help` covers flags and profile settings. Named profiles work with `-p` (or `SUBC_PROFILE`).

## Commands

| Command | Behavior |
| --- | --- |
| `subc claude` | Launch Claude Code |
| `subc codex` | Launch Codex |
| `subc opencode` | Launch OpenCode |
| `subc cursor install` | Install Cursor conversation hooks |
| `subc copilot install` | Install the VS Code Copilot custom endpoint and hooks |
| `subc pi install` then `subc pi` | Merge the Pi provider, then launch |

Pass-through arguments work as usual: `subc claude --continue`, `subc codex exec "write a test"`.

After `subc cursor install`, enable OpenAI API Key Override in Cursor Settings and paste the printed base URL and models. After `subc copilot install`, enter the custom endpoint key once in VS Code's Manage Language Models UI.

Inspect a persistent integration with `subc <agent> status`. Uninstall with `subc <agent> uninstall`.

## Workflow

```text
$ subc claude
# Claude Code starts with your gateway origin and key applied for this session.

> Implement streaming encode/decode for the tokenizer and add tests.
  Search src/     Read tokenizer.ts
  Bash pnpm test  84 passed

Tokenizer trains vocabularies and checks pass.
```

Keep working in the agent. Live traces show up under **Conversations** on the dashboard.
