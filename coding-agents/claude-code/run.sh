#!/usr/bin/env bash
# Point the `claude` CLI at the Subconscious gateway — ephemerally.
#
# Uses env vars only (ANTHROPIC_BASE_URL / ANTHROPIC_AUTH_TOKEN) so nothing is
# written to ~/.claude/ config files.
#
# Usage:
#   ./run.sh                         # uses GATEWAY_URL/API_KEY from ../.env
#   ./run.sh --continue               # pass args through to claude
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
API_KEY="${API_KEY:-}"
MODEL="${MODEL:-gw-glm-5.2}"

if [[ -z "$GATEWAY_URL" || -z "$API_KEY" ]]; then
  echo "error: GATEWAY_URL and API_KEY must be set in ../.env" >&2
  exit 1
fi

# Optional CLAUDE_GATEWAY_URL in shared .env overrides GATEWAY_URL for Claude only.
EFFECTIVE_GATEWAY_URL="${CLAUDE_GATEWAY_URL:-$GATEWAY_URL}"

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

export ANTHROPIC_BASE_URL="$EFFECTIVE_GATEWAY_URL"
export ANTHROPIC_AUTH_TOKEN="$API_KEY"
export ANTHROPIC_MODEL="$MODEL"
export ANTHROPIC_SMALL_FAST_MODEL="$MODEL"
export CLAUDE_CODE_SUBAGENT_MODEL="$MODEL"
export CLAUDE_CODE_MAX_CONCURRENT_SUBAGENTS=4
export CLAUDE_CODE_MAX_SUBAGENT_SPAWN_DEPTH=1
export CLAUDE_CODE_AUTO_COMPACT_WINDOW=3000000
export CLAUDE_CODE_MAX_CONTEXT_TOKENS=3000000
# Claude Code purpose attribution only: api_request logs → gateway POST /v1/logs
# (not a general logs API). Docs:
# https://code.claude.com/docs/en/monitoring-usage#api-request-event
# Requires Claude Code >= 2.1.152.
export CLAUDE_CODE_ENABLE_TELEMETRY=1
export CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1
export OTEL_LOGS_EXPORTER=otlp
export OTEL_EXPORTER_OTLP_PROTOCOL=http/json
export OTEL_EXPORTER_OTLP_LOGS_ENDPOINT="${EFFECTIVE_GATEWAY_URL%/}/v1/logs"
export OTEL_EXPORTER_OTLP_HEADERS="x-api-key=${API_KEY}"
export OTEL_EXPORTER_OTLP_TIMEOUT=2000
export OTEL_LOGS_EXPORT_INTERVAL="${OTEL_LOGS_EXPORT_INTERVAL:-2000}"
# Do not set OTEL_TRACES_EXPORTER / OTEL_METRICS_EXPORTER (including to "none") -
# Claude's telemetry init can abort the whole pipeline on unknown exporter types.
# If sourced, export env and return (caller can unset when done).
if [[ "${BASH_SOURCE[0]:-$0}" != "${0}" ]]; then
  return 0 2>/dev/null || true
fi

# If executed, launch claude with any passed-through args.
exec claude ${PASSTHRU[@]+"${PASSTHRU[@]}"}
