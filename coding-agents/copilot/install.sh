#!/usr/bin/env bash
# ── Subconscious API Gateway — GitHub Copilot in VS Code setup ────────────────
# Point GitHub Copilot Chat in VS Code at your gateway by writing a Custom
# Endpoint provider into VS Code's user-wide chatLanguageModels.json.
#
# Quick start:
#   ./install.sh                        # reads GATEWAY_URL from ../.env
#   ./install.sh --gateway-url https://your-gateway.example
#   ./install.sh status                 # show current config
#   ./install.sh uninstall              # remove the Subconscious provider entry
#
# `install` is the default subcommand. The API key is NOT passed on the command
# line — VS Code requires it to be entered through its UI (the script writes a
# stable ${input:chat.lm.secret.*} reference, and you paste the key once via
# Manage Language Models). `status` and `uninstall` are still available.
#
# Assumes VS Code is installed globally (Code or Code - Insiders). Restart
# VS Code after install so it reloads chatLanguageModels.json.
#
# ── What this does under the hood ────────────────────────────────────────────
# Writes a Custom Endpoint provider entry into chatLanguageModels.json:
#
#   [
#     {
#       "name": "Subconscious Gateway",
#       "vendor": "customendpoint",
#       "apiKey": "${input:chat.lm.secret.subconscious-gateway}",
#       "apiType": "chat-completions",
#       "models": [
#         {
#           "id": "gw-glm-5.2",
#           "name": "Subconscious GLM 5.2",
#           "url": "https://your-gateway.example/v1/chat/completions",
#           "toolCalling": true,
#           "vision": false,
#           "maxInputTokens": 200000,
#           "maxOutputTokens": 16000,
#           "streaming": true,
#           "requestHeaders": { "x-subconscious-client": "copilot" }
#         }
#       ]
#     }
#   ]
#
# The x-subconscious-client: copilot header tags the traffic source so the
# gateway can identify it. Copilot has no native session headers and VS Code's
# Custom Endpoint provider exposes no per-request hook surface, so requests
# are NOT grouped into the dashboard Conversations view — they are metered and
# traced, but land as uncorrelated. See README.md for the full caveat.
# ─────────────────────────────────────────────────────────────────────────────

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load shared env from coding-agents/.env (gitignored) or env.example.
SHARED_ENV="${SCRIPT_DIR}/../.env"
[[ -f "$SHARED_ENV" ]] || SHARED_ENV="${SCRIPT_DIR}/../env.example"
if [[ -f "$SHARED_ENV" ]]; then set -a; source "$SHARED_ENV"; set +a; fi

# Default to `install` so `./install.sh --gateway-url URL` works without an
# explicit `install` subcommand. `status` / `uninstall` still work.
COMMAND="install"
GATEWAY_URL="${GATEWAY_URL:-}"
MODEL="${MODEL:-gw-glm-5.2}"
MAX_INPUT_TOKENS="${MAX_INPUT_TOKENS:-200000}"
MAX_OUTPUT_TOKENS="${MAX_OUTPUT_TOKENS:-16000}"
VSCODE_APP="${VSCODE_APP:-}"  # auto-detected: Code | Code - Insiders | VSCodium

# VS Code's customendpoint provider requires the apiKey to be a
# ${input:chat.lm.secret.<id>} reference into its OS secret store — a plaintext
# key is silently dropped (microsoft/vscode#322299). The secret itself must be
# entered through VS Code's UI ("Add Models" → "Custom Endpoint"). The script
# writes a stable secret id so you only enter the key once.
SECRET_ID="chat.lm.secret.subconscious-gateway"

usage() {
  cat <<'EOF'
Usage:
  install.sh [install] [--gateway-url URL] [--model MODEL]
  install.sh uninstall
  install.sh status

`install` is the default subcommand. The API key is NOT passed on the command
line — VS Code requires it to be entered through its UI (the script writes a
stable ${input:chat.lm.secret.*} reference into chatLanguageModels.json, and
you paste the key once via Manage Language Models).

Writes a "Subconscious Gateway" Custom Endpoint provider into VS Code's
user-wide chatLanguageModels.json. Reads GATEWAY_URL and MODEL from the shared
coding-agents/.env by default. Restart VS Code after install.

Options:
  --gateway-url URL         Gateway origin (default: $GATEWAY_URL from .env)
  --model MODEL             Model id (default: gw-glm-5.2)
  --max-input-tokens N      Model context window input tokens (default: 200000)
  --max-output-tokens N     Model max output tokens (default: 16000)
  --vscode-app APP          Code, Code - Insiders, or VSCodium (auto-detected)

Requires: jq. Restart VS Code after install, then enter your API key once via
Manage Language Models.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    install|uninstall|status)
      COMMAND="$1"
      shift
      ;;
    --gateway-url)
      GATEWAY_URL="${2:-}"
      shift 2
      ;;
    --model)
      MODEL="${2:-}"
      shift 2
      ;;
    --max-input-tokens)
      MAX_INPUT_TOKENS="${2:-}"
      shift 2
      ;;
    --max-output-tokens)
      MAX_OUTPUT_TOKENS="${2:-}"
      shift 2
      ;;
    --vscode-app)
      VSCODE_APP="${2:-}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

PROVIDER_NAME="Subconscious Gateway"
MARKER='Subconscious Gateway'

require_cmds() {
  local missing=0
  for c in jq; do
    if ! command -v "$c" >/dev/null 2>&1; then
      echo "missing required command: $c" >&2
      missing=1
    fi
  done
  if [[ "$missing" -ne 0 ]]; then
    exit 1
  fi
}

# Resolve the VS Code User directory across platforms.
# macOS:   ~/Library/Application Support/Code/User
# Linux:   ~/.config/Code/User
# Windows: %APPDATA%\Code\User (Git Bash: ~/AppData/Roaming/Code/User)
detect_vscode_dir() {
  local app="${VSCODE_APP:-}"
  if [[ -z "$app" ]]; then
    if [[ -d "${HOME}/Library/Application Support/Code/User" ]]; then
      app="Code"
    elif [[ -d "${HOME}/Library/Application Support/Code - Insiders/User" ]]; then
      app="Code - Insiders"
    elif [[ -d "${HOME}/.config/Code/User" ]]; then
      app="Code"
    elif [[ -d "${HOME}/.config/Code - Insiders/User" ]]; then
      app="Code - Insiders"
    elif [[ -d "${HOME}/.config/VSCodium/User" ]]; then
      app="VSCodium"
    elif [[ -d "${HOME}/AppData/Roaming/Code/User" ]]; then
      app="Code"
    else
      echo "could not find a VS Code User directory; pass --vscode-app explicitly" >&2
      exit 1
    fi
  fi

  local user_dir=""
  case "$(uname -s)" in
    Darwin)
      user_dir="${HOME}/Library/Application Support/${app}/User"
      ;;
    Linux)
      user_dir="${HOME}/.config/${app}/User"
      ;;
    MINGW*|MSYS*|CYGWIN*)
      user_dir="${HOME}/AppData/Roaming/${app}/User"
      ;;
    *)
      echo "unsupported platform: $(uname -s)" >&2
      exit 1
      ;;
  esac

  if [[ ! -d "$user_dir" ]]; then
    echo "VS Code User directory not found: $user_dir" >&2
    echo "pass --vscode-app with the correct app name" >&2
    exit 1
  fi
  echo "$user_dir"
}

# The ${input:...} prefix VS Code uses to reference secrets in chatLanguageModels.json.
INPUT_PREFIX='${input:'

# Strip any prior Subconscious provider entry, preserving other providers.
strip_subconscious() {
  local file="$1"
  if [[ ! -f "$file" ]]; then
    echo "[]"
    return
  fi
  jq --arg name "$PROVIDER_NAME" \
    'map(select(.name != $name and ((.name // "") | test("subconscious"; "i") | not)))' \
    "$file" 2>/dev/null || echo "[]"
}

write_config() {
  local user_dir="$1"
  local models_json="${user_dir}/chatLanguageModels.json"
  local base_url="${GATEWAY_URL%/}"
  local chat_url="${base_url}/v1/chat/completions"

  mkdir -p "$user_dir"
  local existing
  existing="$(strip_subconscious "$models_json")"

  local new_provider
  new_provider=$(jq -n \
    --arg name "$PROVIDER_NAME" \
    --arg apiKeyRef "${INPUT_PREFIX}${SECRET_ID}}" \
    --arg modelId "$MODEL" \
    --arg modelName "Subconscious ${MODEL}" \
    --arg url "$chat_url" \
    --argjson maxIn "$MAX_INPUT_TOKENS" \
    --argjson maxOut "$MAX_OUTPUT_TOKENS" \
    '{
      name: $name,
      vendor: "customendpoint",
      apiKey: $apiKeyRef,
      apiType: "chat-completions",
      models: [
        {
          id: $modelId,
          name: $modelName,
          url: $url,
          toolCalling: true,
          vision: false,
          maxInputTokens: $maxIn,
          maxOutputTokens: $maxOut,
          streaming: true,
          requestHeaders: { "x-subconscious-client": "copilot" }
        }
      ]
    }')

  local merged
  merged=$(echo "$existing" | jq --argjson p "$new_provider" '. + [$p]')

  umask 077
  echo "$merged" >"$models_json"
  umask 022
  echo "$models_json"
}

uninstall_config() {
  local user_dir="$1"
  local models_json="${user_dir}/chatLanguageModels.json"
  if [[ -f "$models_json" ]]; then
    if grep -qi "$MARKER" "$models_json" 2>/dev/null; then
      local tmp
      tmp="$(mktemp)"
      jq --arg name "$PROVIDER_NAME" \
        'map(select(.name != $name and ((.name // "") | test("subconscious"; "i") | not)))' \
        "$models_json" >"$tmp"
      mv "$tmp" "$models_json"
      echo "Removed Subconscious provider from $models_json"
    else
      echo "No Subconscious provider found in $models_json"
    fi
  else
    echo "No chatLanguageModels.json at $models_json"
  fi
}

status() {
  local user_dir="$1"
  local models_json="${user_dir}/chatLanguageModels.json"
  echo "scope: user"
  echo "vscode user dir: $user_dir"
  echo "config: $models_json"
  if [[ -f "$models_json" ]] && grep -qi "$MARKER" "$models_json" 2>/dev/null; then
    echo "status: installed"
    echo "provider: $(jq -r --arg name "$PROVIDER_NAME" '.[] | select(.name == $name) | .name' "$models_json" 2>/dev/null || echo 'unknown')"
    echo "model: $(jq -r --arg name "$PROVIDER_NAME" '.[] | select(.name == $name) | .models[0].id' "$models_json" 2>/dev/null || echo 'unknown')"
    echo "url: $(jq -r --arg name "$PROVIDER_NAME" '.[] | select(.name == $name) | .models[0].url' "$models_json" 2>/dev/null || echo 'unknown')"
  else
    echo "status: not installed"
  fi
}

case "$COMMAND" in
  install)
    require_cmds
    if [[ -z "$GATEWAY_URL" ]]; then
      echo "--gateway-url is required for install (or set GATEWAY_URL in .env)" >&2
      exit 1
    fi
    USER_DIR="$(detect_vscode_dir)"
    WRITTEN="$(write_config "$USER_DIR")"
    echo "Installed Subconscious Copilot provider into $WRITTEN"
    echo ""
    echo "IMPORTANT: VS Code requires the API key to be stored in its secret"
    echo "store — a plaintext key in the JSON is silently dropped. You must"
    echo "enter the key once through the VS Code UI:"
    echo ""
    echo "  1. Restart VS Code (fully quit, not just reload)."
    echo "  2. Open Chat → model picker (gear) → Manage Language Models."
    echo "  3. Find 'Subconscious Gateway' → click the key icon to set the API key."
    echo "  4. Paste your gateway API key (sk-gw-...)."
    echo ""
    echo "After that, select 'Subconscious ${MODEL}' from the model picker."
    echo "The script writes a stable secret id (${SECRET_ID}) so you only do this once."
    ;;
  uninstall)
    require_cmds
    USER_DIR="$(detect_vscode_dir)"
    uninstall_config "$USER_DIR"
    echo "Restart VS Code for the change to take effect."
    ;;
  status)
    require_cmds
    USER_DIR="$(detect_vscode_dir)"
    status "$USER_DIR"
    ;;
esac
