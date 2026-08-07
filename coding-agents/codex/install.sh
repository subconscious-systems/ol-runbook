#!/usr/bin/env bash
# ── Subconscious API Gateway — Codex setup ────────────────────────────────────
# Point the Codex CLI at your gateway. Writes a provider config with session
# headers so the gateway can correlate Codex requests into Conversations.
#
# Quick start:
#   ./install.sh --gateway-url https://your-gateway.example --api-key sk-gw-...
#   ./install.sh use                    # launches codex with gateway env loaded
#   ./install.sh use -- --resume        # pass args through to codex
#
# Or source env into your shell:
#   source <(./install.sh env)          # load   SUBCONSCIOUS_API_KEY
#   source <(./install.sh unset)        # remove SUBCONSCIOUS_API_KEY
#
#   ./install.sh status                 # show current config
#   ./install.sh uninstall              # remove config + env file
#
# ── Subagents ─────────────────────────────────────────────────────────────────
# Subagents are OFF by default. Current Codex releases (>=0.144) wrap subagent
# tools in a `type: "namespace"` wire format that non-OpenAI providers can't
# resolve, causing "unsupported call: spawn_agent" errors (upstream #32318,
# #26977, #17598). The fix (PR #29602) is not yet merged.
#
# To use subagents, install the legacy Codex 0.132.0 which uses the older
# multi-agent v1 config with plain tool names:
#
#   ./install.sh --subagents --gateway-url ... --api-key ...
#
# This pins `codex@0.132.0` and writes the legacy agents config:
#
#   [features]
#   multi_agent = true
#
#   [agents]
#   max_threads = 4
#   max_depth = 1
#   interrupt_message = true
#
# ── What this does under the hood ────────────────────────────────────────────
# Equivalent manual setup (writes ~/.codex/config.toml + model catalog + env):
#
#   export SUBCONSCIOUS_API_KEY=sk-gw-...
#   cat > ~/.codex/model-catalog.json <<'EOF'
#   { "models": [{ ... }] }
#   EOF
#
#   cat > ~/.codex/config.toml <<'EOF'
#   model = "gw-glm-5.2"
#   model_provider = "subconscious"
#   model_catalog_json = "~/.codex/model-catalog.json"
#   web_search = "disabled"
#
#   [model_providers.subconscious]
#   name = "Subconscious Gateway"
#   base_url = "https://your-gateway.example/v1"
#   wire_api = "responses"
#   env_key = "SUBCONSCIOUS_API_KEY"
#   stream_idle_timeout_ms = 300000
#   EOF
#   codex
#
# Codex natively sends thread-id / session-id / x-codex-turn-metadata headers
# so the gateway can group requests into Conversations.
# ─────────────────────────────────────────────────────────────────────────────

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load shared env from coding-agents/.env (gitignored) or env.example.
SHARED_ENV="${MBTA_ENV_FILE:-${SCRIPT_DIR}/../.env}"
[[ -f "$SHARED_ENV" ]] || SHARED_ENV="${SCRIPT_DIR}/../env.example"
if [[ -f "$SHARED_ENV" ]]; then set -a; source "$SHARED_ENV"; set +a; fi

COMMAND="install"
GATEWAY_URL="${GATEWAY_URL:-}"
API_KEY="${CODEX_API_KEY:-${API_KEY:-}}"
MODEL="${MODEL:-gw-glm-5.2}"
SUBAGENTS=false
MAX_CONCURRENT_SUBAGENTS="${MAX_CONCURRENT_SUBAGENTS:-4}"
CODEX_CONTEXT_WINDOW="${CODEX_CONTEXT_WINDOW:-5000000}"
# Empty means "same as context window" after CLI/env resolution.
CODEX_MAX_CONTEXT_WINDOW="${CODEX_MAX_CONTEXT_WINDOW:-}"
CODEX_AUTO_COMPACT_TOKEN_LIMIT="${CODEX_AUTO_COMPACT_TOKEN_LIMIT:-4500000}"

# Codex version that supports the legacy multi-agent v1 config (plain tool names).
SUBAGENT_CODEX_VERSION="0.132.0"

usage() {
  cat <<'EOF'
Usage:
  install.sh [install] --gateway-url URL --api-key KEY [--model MODEL]
                         [--subagents] [--max-concurrent-subagents N]
                         [--context-window N] [--max-context-window N]
                         [--auto-compact-token-limit N]
  install.sh use [-- CODEX_ARGS...]
  install.sh env
  install.sh unset
  install.sh uninstall
  install.sh status

`install` is the default subcommand and may be omitted.

Commands:
  install     Write ~/.codex/config.toml + ~/.codex/subconscious.env
  use         Source the env file and exec codex (pass -- followed by codex args)
  env         Print export lines for sourcing: source <(./install.sh env)
  unset       Print unset lines for sourcing: source <(./install.sh unset)
  uninstall   Remove the config and env file
  status      Show current configuration

Options:
  --gateway-url URL            Gateway origin (e.g. https://gateway.example)
  --api-key KEY                Gateway API key (sk-gw-...)
  --model MODEL                Model name (default: gw-glm-5.2)
  --context-window N           Catalog context_window (default: 5000000 / CODEX_CONTEXT_WINDOW)
  --max-context-window N       Catalog max_context_window (default: same as context window)
  --auto-compact-token-limit N Catalog auto_compact_token_limit (default: 4500000)
  --subagents                  Enable subagents (pins codex@0.132.0, writes legacy
                               multi-agent v1 config with plain tool names)
  --max-concurrent-subagents N Max concurrent subagent threads (default: 4,
                               only used with --subagents)
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    install|use|env|unset|uninstall|status)
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
    --context-window)
      CODEX_CONTEXT_WINDOW="${2:-}"
      shift 2
      ;;
    --max-context-window)
      CODEX_MAX_CONTEXT_WINDOW="${2:-}"
      shift 2
      ;;
    --auto-compact-token-limit)
      CODEX_AUTO_COMPACT_TOKEN_LIMIT="${2:-}"
      shift 2
      ;;
    --subagents)
      SUBAGENTS=true
      shift
      ;;
    --max-concurrent-subagents)
      MAX_CONCURRENT_SUBAGENTS="${2:-}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --)
      shift
      break
      ;;
    *)
      echo "unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

# Default max_context_window to context_window when unset.
CODEX_MAX_CONTEXT_WINDOW="${CODEX_MAX_CONTEXT_WINDOW:-${CODEX_CONTEXT_WINDOW}}"

CODEX_DIR="${HOME}/.codex"
CONFIG_TOML="${CODEX_DIR}/config.toml"
ENV_FILE="${CODEX_DIR}/subconscious.env"
CATALOG_FILE="${CODEX_DIR}/model-catalog.json"
MARKER='model_provider = "subconscious"'

write_config() {
  mkdir -p "$CODEX_DIR"
  local base_url="${GATEWAY_URL%/}/v1"

  # Codex does not load custom model metadata from config.toml — it needs a
  # JSON catalog pointed to by the root-level `model_catalog_json` key.
  # Without this, Codex prints "Model metadata not found" and falls back to
  # degraded defaults. The catalog is a replacement, not a merge, so it only
  # contains our custom model.
  cat >"$CATALOG_FILE" <<'ENDJSON'
{
  "models": [
    {
      "slug": "__MODEL__",
      "display_name": "Subconscious GLM 5.2",
      "description": "Subconscious API Gateway GLM 5.2",
      "context_window": __CONTEXT_WINDOW__,
      "max_context_window": __MAX_CONTEXT_WINDOW__,
      "auto_compact_token_limit": __AUTO_COMPACT_TOKEN_LIMIT__,
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
  # Substitute model slug + context limits into the catalog.
  # On macOS, sed -i requires an empty backup extension arg.
  sed -i '' \
    -e "s/__MODEL__/${MODEL}/g" \
    -e "s/__CONTEXT_WINDOW__/${CODEX_CONTEXT_WINDOW}/g" \
    -e "s/__MAX_CONTEXT_WINDOW__/${CODEX_MAX_CONTEXT_WINDOW}/g" \
    -e "s/__AUTO_COMPACT_TOKEN_LIMIT__/${CODEX_AUTO_COMPACT_TOKEN_LIMIT}/g" \
    "$CATALOG_FILE"

  # Write config.toml. When --subagents is set, write the legacy multi-agent v1
  # config that uses plain tool names (not namespace wrappers), which the model
  # worker can actually resolve. Otherwise, omit the [agents] block entirely so
  # Codex uses its defaults (subagents off for custom providers).
  if [[ "$SUBAGENTS" == "true" ]]; then
    cat >"$CONFIG_TOML" <<EOF
model = "${MODEL}"
model_provider = "subconscious"
model_catalog_json = "${CATALOG_FILE}"
web_search = "disabled"

[features]
multi_agent = true

[agents]
max_threads = ${MAX_CONCURRENT_SUBAGENTS}
max_depth = 1
interrupt_message = true

[model_providers.subconscious]
name = "Subconscious Gateway"
base_url = "${base_url}"
wire_api = "responses"
env_key = "SUBCONSCIOUS_API_KEY"
stream_idle_timeout_ms = 300000
EOF
  else
    cat >"$CONFIG_TOML" <<EOF
model = "${MODEL}"
model_provider = "subconscious"
model_catalog_json = "${CATALOG_FILE}"
web_search = "disabled"

[model_providers.subconscious]
name = "Subconscious Gateway"
base_url = "${base_url}"
wire_api = "responses"
env_key = "SUBCONSCIOUS_API_KEY"
stream_idle_timeout_ms = 300000
EOF
  fi

  umask 077
  cat >"$ENV_FILE" <<EOF
# Generated by ol-runbook/coding-agents/codex/install.sh — do not commit secrets.
export SUBCONSCIOUS_API_KEY='${API_KEY}'
EOF
  chmod 600 "$ENV_FILE"
}

print_env_exports() {
  if [[ ! -f "$ENV_FILE" ]]; then
    echo "env file not found: $ENV_FILE" >&2
    echo "run: ./install.sh --gateway-url URL --api-key KEY" >&2
    return 1
  fi
  cat "$ENV_FILE"
}

print_env_unsets() {
  cat <<'EOF'
unset SUBCONSCIOUS_API_KEY
EOF
}

uninstall_config() {
  if [[ -f "$CONFIG_TOML" ]] && grep -q "$MARKER" "$CONFIG_TOML" 2>/dev/null; then
    rm -f "$CONFIG_TOML"
    echo "Removed $CONFIG_TOML"
  else
    echo "No Subconscious Codex config found at $CONFIG_TOML"
  fi
  rm -f "$ENV_FILE"
  if [[ -f "$CATALOG_FILE" ]]; then
    rm -f "$CATALOG_FILE"
    echo "Removed $CATALOG_FILE"
  fi
}

status() {
  echo "scope: user"
  echo "codex dir: $CODEX_DIR"
  echo "config: $CONFIG_TOML"
  if [[ -f "$CONFIG_TOML" ]] && grep -q "$MARKER" "$CONFIG_TOML" 2>/dev/null; then
    echo "status: installed"
    echo "model: $(grep '^model' "$CONFIG_TOML" | head -1 | sed 's/^model = "//;s/"$//')"
    echo "base_url: $(grep 'base_url' "$CONFIG_TOML" | sed 's/^base_url = "//;s/"$//')"
    if grep -q '^\[agents\]' "$CONFIG_TOML" 2>/dev/null; then
      echo "subagents: enabled (legacy multi-agent v1)"
      local maxt
      maxt="$(awk -F' *= *' '/^max_threads *=/{print $2}' "$CONFIG_TOML")"
      echo "  max_threads: ${maxt:-?}"
    else
      echo "subagents: disabled (codex defaults)"
    fi
  else
    echo "status: not installed"
  fi
  if [[ -f "$ENV_FILE" ]]; then
    echo "env: $ENV_FILE (present)"
  else
    echo "env: missing"
  fi
}

case "$COMMAND" in
  install)
    if [[ -z "$GATEWAY_URL" || -z "$API_KEY" ]]; then
      echo "--gateway-url and --api-key are required for install" >&2
      exit 1
    fi
    write_config
    echo "Installed Subconscious Codex config at $CONFIG_TOML"
    echo "  gateway: $GATEWAY_URL"
    echo "  model:   $MODEL"
    if [[ "$SUBAGENTS" == "true" ]]; then
      echo "  subagents: ENABLED (codex@${SUBAGENT_CODEX_VERSION}, max ${MAX_CONCURRENT_SUBAGENTS} threads)"
      echo ""
      echo "  NOTE: Subagent mode pins codex@${SUBAGENT_CODEX_VERSION}."
      echo "  Install it with:  npm install -g @openai/codex@${SUBAGENT_CODEX_VERSION}"
      echo "  Then launch with: ./install.sh use"
    else
      echo "  subagents: disabled (default for custom providers)"
    fi
    echo ""
    echo "Launch codex:"
    echo "  ./install.sh use"
    echo "  ./install.sh use -- --resume"
    echo ""
    echo "Or source env into your current shell:"
    echo "  source <(./install.sh env)"
    ;;
  use)
    if [[ ! -f "$ENV_FILE" ]]; then
      echo "env file not found: $ENV_FILE" >&2
      echo "run: ./install.sh --gateway-url URL --api-key KEY" >&2
      exit 1
    fi
    # shellcheck disable=SC1090
    source "$ENV_FILE"
    # If subagents are enabled, ensure the pinned legacy version is installed.
    if [[ "$SUBAGENTS" == "true" ]]; then
      if ! command -v codex >/dev/null 2>&1; then
        echo "codex CLI not found in PATH" >&2
        echo "Install the pinned subagent version:" >&2
        echo "  npm install -g @openai/codex@${SUBAGENT_CODEX_VERSION}" >&2
        exit 1
      fi
      local_version="$(codex --version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' || echo "")"
      if [[ "$local_version" != "$SUBAGENT_CODEX_VERSION" ]]; then
        echo "WARNING: codex ${local_version:-unknown} is installed, but subagents need ${SUBAGENT_CODEX_VERSION}." >&2
        echo "  npm install -g @openai/codex@${SUBAGENT_CODEX_VERSION}" >&2
        echo "  (or remove --subagents from your config to use the latest codex without subagents)" >&2
      fi
    else
      if ! command -v codex >/dev/null 2>&1; then
        echo "codex CLI not found in PATH" >&2
        exit 1
      fi
    fi
    exec codex "$@"
    ;;
  env)
    print_env_exports
    ;;
  unset)
    print_env_unsets
    ;;
  uninstall)
    uninstall_config
    echo "To unset env in your current shell: source <(./install.sh unset)"
    ;;
  status)
    status
    ;;
esac
