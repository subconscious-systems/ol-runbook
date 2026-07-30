#!/usr/bin/env bash
# Point the `codex` CLI at the Subconscious gateway — ephemerally.
#
# Uses `codex -c key=value` overrides so nothing is written to ~/.codex/config.toml.
# web_search is disabled so Codex doesn't send hosted tools the gateway can't execute.
# The model catalog (needed to suppress the "model metadata not found" warning)
# is written to a temp file that is cleaned up on exit.
#
# Subagents are OFF by default. Current Codex (>=0.144) wraps subagent tools in a
# `type: "namespace"` wire format that non-OpenAI providers can't resolve, causing
# "unsupported call: spawn_agent" (upstream #32318, #26977). The fix (PR #29602) is
# not yet merged.
#
# To run with subagents, pass --subagents — this runs the pinned legacy
# codex@0.132.0 with multi-agent v1 config (plain tool names) that the model can
# resolve. Requires npx.
#
# Usage:
#   ./run.sh                         # uses GATEWAY_URL/API_KEY from ../.env
#   ./run.sh -- --resume              # pass args through to codex
#   ./run.sh --subagents              # run codex@0.132.0 with subagents enabled
#   ./run.sh --subagents -- --resume  # subagents + passthrough args
#
# Config: copy ../env.example to ../.env and edit. .env is gitignored.
# All agents share one coding-agents/.env file.
#
# Or source it to just export the env:
#   source run.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load shared env from coding-agents/.env (gitignored) or env.example.
SHARED_ENV="${SCRIPT_DIR}/../.env"
[[ -f "$SHARED_ENV" ]] || SHARED_ENV="${SCRIPT_DIR}/../env.example"
if [[ -f "$SHARED_ENV" ]]; then set -a; source "$SHARED_ENV"; set +a; fi

GATEWAY_URL="${GATEWAY_URL:-}"
API_KEY="${API_KEY:-}"
MODEL="${MODEL:-gw-glm-5.2}"
MAX_CONCURRENT_SUBAGENTS="${MAX_CONCURRENT_SUBAGENTS:-4}"
SUBAGENTS=false

# Codex version that supports the legacy multi-agent v1 config (plain tool names).
SUBAGENT_CODEX_VERSION="0.132.0"

if [[ -z "$GATEWAY_URL" || -z "$API_KEY" ]]; then
  echo "error: GATEWAY_URL and API_KEY must be set in ../.env" >&2
  exit 1
fi

# Parse args (only when executed, not sourced)
PASSTHRU=()
if [[ "${BASH_SOURCE[0]:-$0}" == "${0}" ]]; then
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --subagents)
        SUBAGENTS=true
        shift
        ;;
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

export SUBCONSCIOUS_API_KEY="$API_KEY"

# Write a temp model catalog so Codex doesn't print "model metadata not found".
# This is the one thing that can't be passed via -c flags.
CATALOG_FILE="$(mktemp -t codex-model-catalog.XXXXXX.json)"
cleanup() { rm -f "$CATALOG_FILE"; }
trap cleanup EXIT

cat >"$CATALOG_FILE" <<'ENDJSON'
{
  "models": [
    {
      "slug": "__MODEL__",
      "display_name": "Subconscious GLM 5.2",
      "description": "Subconscious API Gateway GLM 5.2",
      "context_window": 200000,
      "max_context_window": 200000,
      "auto_compact_token_limit": 180000,
      "effective_context_window_percent": 95,
      "supported_reasoning_levels": [],
      "shell_type": "shell_command",
      "visibility": "list",
      "supported_in_api": true,
      "priority": 0,
      "availability_nux": null,
      "upgrade": null,
      "base_instructions": "You are Codex, a coding agent.",
      "supports_reasoning_summaries": false,
      "support_verbosity": false,
      "default_verbosity": null,
      "apply_patch_tool_type": "freeform",
      "truncation_policy": { "mode": "tokens", "limit": 10000 },
      "supports_parallel_tool_calls": true,
      "experimental_supported_tools": []
    }
  ]
}
ENDJSON
sed -i '' "s/__MODEL__/${MODEL}/g" "$CATALOG_FILE"

# If sourced, just export env and return.
if [[ "${BASH_SOURCE[0]:-$0}" != "${0}" ]]; then
  export GATEWAY_URL CATALOG_FILE MAX_CONCURRENT_SUBAGENTS SUBAGENTS
  return 0 2>/dev/null || true
fi

# Ephemeral config via -c flags — nothing is written to ~/.codex/config.toml.
if [[ "$SUBAGENTS" == "true" ]]; then
  # Legacy multi-agent v1 config — plain tool names the model can resolve.
  echo "Starting codex@${SUBAGENT_CODEX_VERSION} with subagents enabled (max ${MAX_CONCURRENT_SUBAGENTS} threads)..." >&2
  exec npx -y "@openai/codex@${SUBAGENT_CODEX_VERSION}" \
    -c model="${MODEL}" \
    -c model_provider=subconscious \
    -c model_catalog_json="${CATALOG_FILE}" \
    -c web_search=disabled \
    -c features.multi_agent=true \
    -c agents.max_threads="${MAX_CONCURRENT_SUBAGENTS}" \
    -c agents.max_depth=1 \
    -c agents.interrupt_message=true \
    -c model_providers.subconscious.name=Subconscious \
    -c model_providers.subconscious.base_url="${GATEWAY_URL}/v1" \
    -c model_providers.subconscious.wire_api=responses \
    -c model_providers.subconscious.env_key=SUBCONSCIOUS_API_KEY \
    -c model_providers.subconscious.stream_idle_timeout_ms=300000 \
    ${PASSTHRU[@]+"${PASSTHRU[@]}"}
else
  exec codex \
    -c model="${MODEL}" \
    -c model_provider=subconscious \
    -c model_catalog_json="${CATALOG_FILE}" \
    -c web_search=disabled \
    -c model_providers.subconscious.name=Subconscious \
    -c model_providers.subconscious.base_url="${GATEWAY_URL}/v1" \
    -c model_providers.subconscious.wire_api=responses \
    -c model_providers.subconscious.env_key=SUBCONSCIOUS_API_KEY \
    -c model_providers.subconscious.stream_idle_timeout_ms=300000 \
    ${PASSTHRU[@]+"${PASSTHRU[@]}"}
fi
