#!/usr/bin/env bash
# Point OpenCode at the Subconscious gateway — ephemerally.
#
# Exports SUBCONSCIOUS_API_KEY and OPENCODE_CONFIG_CONTENT as env vars so
# nothing is written to ~/.opencode/opencode.json. OpenCode reads the
# config from the OPENCODE_CONFIG_CONTENT env var at startup.
#
# Usage:
#   ./run.sh                         # uses GATEWAY_URL/API_KEY from ../.env
#   ./run.sh -- auth                 # pass args through to opencode
#
# Config: copy ../env.example to ../.env and edit. .env is gitignored.
# All agents share one coding-agents/.env file.
#
# Or source it to just export the env:
#   source run.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load shared env from coding-agents/.env (gitignored) or env.example.
SHARED_ENV="${MBTA_ENV_FILE:-${SCRIPT_DIR}/../.env}"
[[ -f "$SHARED_ENV" ]] || SHARED_ENV="${SCRIPT_DIR}/../env.example"
if [[ -f "$SHARED_ENV" ]]; then set -a; source "$SHARED_ENV"; set +a; fi

GATEWAY_URL="${GATEWAY_URL:-}"
API_KEY="${OPENCODE_API_KEY:-${API_KEY:-}}"
MODEL="${MODEL:-gw-glm-5.2}"

if [[ -z "$GATEWAY_URL" || -z "$API_KEY" ]]; then
  echo "error: GATEWAY_URL and API_KEY must be set in ../.env" >&2
  exit 1
fi

# Parse args (only when executed, not sourced)
PASSTHRU=()
if [[ "${BASH_SOURCE[0]:-$0}" == "${0}" ]]; then
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --)
        shift
        PASSTHRU+=("$@")
        break
        ;;
      *)
        PASSTHRU+=("$1")
        shift
        ;;
    esac
  done
fi

BASE_URL="${GATEWAY_URL%/}/v1"

export SUBCONSCIOUS_API_KEY="$API_KEY"
# Read by the compaction plugin when it is installed. run.sh writes nothing to disk, so
# use install.sh if you want compaction reporting.
export SUBCONSCIOUS_GATEWAY_URL="${GATEWAY_URL%/}"
export OPENCODE_CONFIG_CONTENT=$(cat <<EOF
{"\$schema":"https://opencode.ai/config.json","provider":{"subconscious":{"npm":"@ai-sdk/openai-compatible","name":"Subconscious Gateway","options":{"baseURL":"${BASE_URL}","apiKey":"{env:SUBCONSCIOUS_API_KEY}","headers":{"x-subconscious-client":"opencode"}},"models":{"${MODEL}":{"name":"${MODEL}","tools":true}}}},"model":"subconscious/${MODEL}"}
EOF
)

# If sourced, just export env and return.
if [[ "${BASH_SOURCE[0]:-$0}" != "${0}" ]]; then
  return 0 2>/dev/null || true
fi

exec opencode ${PASSTHRU[@]+"${PASSTHRU[@]}"}
