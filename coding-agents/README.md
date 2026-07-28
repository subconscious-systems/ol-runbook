# Coding Agents

Point your coding agents at the Subconscious API Gateway. Each agent has an
`install.sh` (persistent config) and some have a `run.sh` (ephemeral, no
persistent config). All scripts read gateway settings from a shared `.env` file.

## Quick start

```bash
cd ol-runbook/coding-agents

# One-time: copy the shared env and paste in your values
cp env.example .env

# Install any agent (reads GATEWAY_URL + API_KEY from .env)
./cursor/install.sh
./claude-code/install.sh
./codex/install.sh
./opencode/install.sh
./pi/install.sh
./copilot/install.sh   # VS Code: API key entered via UI after install
```

## Shared env file

All scripts read from `coding-agents/.env` (gitignored). Copy `env.example`
to `.env` and fill in your keys:

| Variable | Purpose |
| --- | --- |
| `GATEWAY_URL` | Gateway origin (e.g. `https://gateway.example.com`) |
| `API_KEY` | Gateway API key (`sk-gw-...`) |
| `MODEL` | Model name (default: `gw-glm-5.2`) |

`install.sh` scripts also accept `--gateway-url` / `--api-key` flags which
override the env file values.

## Which agent do I use?

| Agent | API surface | Correlation method | Persistent install | Ephemeral runner |
| --- | --- | --- | --- | --- |
| **[Cursor](cursor/)** | `POST /v1/chat/completions` | Hook script + prompt fingerprint soft-bind | `cursor/install.sh` | — |
| **[Claude Code](claude-code/)** | `POST /v1/messages` | Native `x-claude-code-session-id` headers | `claude-code/install.sh` | `claude-code/run.sh` |
| **[Codex](codex/)** | `POST /v1/responses` | Native `thread-id` / session metadata | `codex/install.sh` | `codex/run.sh` |
| **[OpenCode](opencode/)** | `POST /v1/chat/completions` | Native `x-session-affinity` / `x-session-id` | `opencode/install.sh` | `opencode/run.sh` |
| **[Pi](pi/)** | `POST /v1/chat/completions` | `x-session-id` / `x-session-affinity` (compat flags) | `pi/install.sh` | — |
| **[Copilot (VS Code)](copilot/)** | `POST /v1/chat/completions` | Hook script + prompt fingerprint soft-bind | `copilot/install.sh` | — |

## Layout

```
coding-agents/
├── .env                # your keys (gitignored)
├── .gitignore
├── env.example         # template — copy to .env
├── README.md           # this file
├── cursor/
│   ├── install.sh
│   ├── hook.sh
│   └── hooks.json
├── claude-code/
│   ├── install.sh
│   ├── run.sh
│   └── README.md
├── codex/
│   ├── install.sh
│   ├── run.sh
│   └── README.md
├── opencode/
│   ├── install.sh
│   ├── run.sh
│   └── README.md
├── pi/
│   ├── install.sh
│   └── README.md
└── copilot/
    ├── install.sh
    ├── hook.sh
    ├── hooks.json
    └── README.md
```
