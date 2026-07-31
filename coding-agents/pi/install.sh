#!/usr/bin/env bash
# ── Subconscious API Gateway — Pi setup ───────────────────────────────────────
# Point the Pi CLI at your gateway. Writes a model config with session headers
# so the gateway can correlate Pi requests into Conversations.
#
# Quick start:
#   ./install.sh --gateway-url https://your-gateway.example --api-key sk-gw-...
#   ./install.sh status                 # show current config
#   ./install.sh uninstall              # revert to default model config
#
# Writes ~/.pi/agent/models.json (user config). Restart Pi after install.
#
# ── What this does under the hood ────────────────────────────────────────────
# Equivalent manual setup (writes ~/.pi/agent/models.json):
#
#   {
#     "providers": {
#       "subconscious": {
#         "baseUrl": "https://your-gateway.example/v1",
#         "api": "openai-completions",
#         "apiKey": "sk-gw-...",
#         "headers": { "x-subconscious-client": "pi" },
#         "models": [{
#           "id": "gw-glm-5.2",
#           "compat": {
#             "sendSessionAffinityHeaders": true,
#             "sessionAffinityFormat": "openai-nosession"
#           }
#         }]
#       }
#     }
#   }
#
# The compat flags make Pi send x-session-id and x-session-affinity headers
# so the gateway groups requests into Conversations.
# ─────────────────────────────────────────────────────────────────────────────

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load shared env from coding-agents/.env (gitignored) or env.example.
SHARED_ENV="${MBTA_ENV_FILE:-${SCRIPT_DIR}/../.env}"
[[ -f "$SHARED_ENV" ]] || SHARED_ENV="${SCRIPT_DIR}/../env.example"
if [[ -f "$SHARED_ENV" ]]; then set -a; source "$SHARED_ENV"; set +a; fi

COMMAND="install"
GATEWAY_URL="${GATEWAY_URL:-}"
API_KEY="${API_KEY:-}"
MODEL="${MODEL:-gw-glm-5.2}"

usage() {
  cat <<'EOF'
Usage:
  install.sh [install] --gateway-url URL --api-key KEY [--model MODEL]
  install.sh uninstall
  install.sh status

`install` is the default subcommand and may be omitted.

Writes a models.json that points Pi at your Subconscious gateway with
x-subconscious-client: pi and session-affinity headers enabled so the gateway
can group requests into Conversations.

Pi does not send session headers by default; this script enables
sendSessionAffinityHeaders with sessionAffinityFormat "openai-nosession"
(sends x-session-affinity without the underscore session_id header that
strict proxies may drop).

Requires: jq. Restart Pi after install.
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
    --api-key)
      API_KEY="${2:-}"
      shift 2
      ;;
    --model)
      MODEL="${2:-}"
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

PI_DIR="${HOME}/.pi/agent"
MODELS_JSON="${PI_DIR}/models.json"
MARKER='x-subconscious-client'

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

write_config() {
  mkdir -p "$PI_DIR"
  local base_url="${GATEWAY_URL%/}/v1"
  local config
  config=$(cat <<EOF
{
  "providers": {
    "subconscious": {
      "baseUrl": "${base_url}",
      "api": "openai-completions",
      "apiKey": "${API_KEY}",
      "headers": {
        "x-subconscious-client": "pi"
      },
      "models": [
        {
          "id": "${MODEL}",
          "compat": {
            "sendSessionAffinityHeaders": true,
            "sessionAffinityFormat": "openai-nosession"
          }
        }
      ]
    }
  }
}
EOF
)
  echo "$config" >"$MODELS_JSON"
  chmod 600 "$MODELS_JSON"
}

uninstall_config() {
  if [[ -f "$MODELS_JSON" ]] && grep -q "$MARKER" "$MODELS_JSON" 2>/dev/null; then
    rm -f "$MODELS_JSON"
    echo "Removed $MODELS_JSON"
  else
    echo "No Subconscious Pi config found at $MODELS_JSON"
  fi
}

status() {
  echo "scope: user"
  echo "pi dir: $PI_DIR"
  echo "config: $MODELS_JSON"
  if [[ -f "$MODELS_JSON" ]] && grep -q "$MARKER" "$MODELS_JSON" 2>/dev/null; then
    echo "status: installed"
    echo "model: $(jq -r '.providers.subconscious.models[0].id // "unset"' "$MODELS_JSON" 2>/dev/null || echo 'unknown')"
  else
    echo "status: not installed"
  fi
}

case "$COMMAND" in
  install)
    require_cmds
    if [[ -z "$GATEWAY_URL" || -z "$API_KEY" ]]; then
      echo "--gateway-url and --api-key are required for install" >&2
      exit 1
    fi
    write_config
    echo "Installed Subconscious Pi config at $MODELS_JSON"
    echo "Restart any running Pi sessions."
    ;;
  uninstall)
    uninstall_config
    ;;
  status)
    status
    ;;
esac
