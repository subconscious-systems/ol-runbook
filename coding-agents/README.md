# Coding Agents

Point your coding agents at the Subconscious API Gateway. Use the **`mbta`**
CLI (preferred) or the per-agent `install.sh` / `run.sh` scripts. All of them
read gateway settings from a shared env file (default profile: `.env`).

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

`default` lives at `coding-agents/.env`. Named profiles live under
`coding-agents/profiles/<name>.env`:

```bash
mbta config --profile staging --gateway-url https://staging.example --api-key sk-gw-...
mbta --profile staging cursor install
mbta -p staging claude-code run
mbta config list
```

You can also set `MBTA_PROFILE=staging`. Direct `./cursor/install.sh` always
uses the default `.env` unless `MBTA_ENV_FILE` is set.

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

| Variable | Purpose |
| --- | --- |
| `GATEWAY_URL` | Gateway origin (e.g. `https://gateway.example.com`) |
| `API_KEY` | Gateway API key (`sk-gw-...`) |
| `MODEL` | Model name (default: `gw-glm-5.2`) |

Prefer `mbta config` (or editing `.env`) over passing credentials on the
command line. `install.sh` scripts also accept `--gateway-url` / `--api-key`
flags which override the env file for a one-off.

## CLI reference (`mbta`)

```text
mbta self-install [--bin-dir DIR]
mbta self-uninstall
mbta config [--profile NAME] --gateway-url URL --api-key KEY [--model MODEL]
mbta config show|path|list
mbta config delete --profile NAME
mbta [--profile NAME] <agent> install|status|uninstall|run …
```

Agents: `cursor`, `copilot` (`vscode`), `claude-code` (`claude`), `codex`,
`opencode`, `pi`.

Platform / bootstrap commands are not on this CLI yet.

## Which agent do I use?

| Agent | API surface | Correlation method | Persistent install | Ephemeral runner |
| --- | --- | --- | --- | --- |
| **[Cursor](cursor/)** | `POST /v1/chat/completions` | Hook script + prompt fingerprint soft-bind | `mbta cursor install` | — (see `mbta cursor run`) |
| **[Claude Code](claude-code/)** | `POST /v1/messages` | Native `x-claude-code-session-id` headers | `mbta claude-code install` | `mbta claude-code run` |
| **[Codex](codex/)** | `POST /v1/responses` | Native `thread-id` / session metadata | `mbta codex install` | `mbta codex run` |
| **[OpenCode](opencode/)** | `POST /v1/chat/completions` | Native `x-session-affinity` / `x-session-id` | `mbta opencode install` | `mbta opencode run` |
| **[Pi](pi/)** | `POST /v1/chat/completions` | `x-session-id` / `x-session-affinity` (compat flags) | `mbta pi install` | — |
| **[Copilot (VS Code)](copilot/)** | `POST /v1/chat/completions` | Hook script + prompt fingerprint soft-bind | `mbta copilot install` | — |
