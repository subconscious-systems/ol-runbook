#!/usr/bin/env bash
# Shared helpers for the mbta CLI (sourced by ../../mbta).
# Not intended to be executed directly.

# Resolve OL_RUNBOOK_ROOT and CODING_AGENTS_DIR from the realpath of the mbta
# entrypoint. Call with: mbta_init_paths "$BASH_SOURCE_OF_MBTA"
mbta_init_paths() {
  local entry="$1"
  local resolved
  if command -v realpath >/dev/null 2>&1; then
    resolved="$(realpath "$entry")"
  elif command -v readlink >/dev/null 2>&1; then
    resolved="$(readlink -f "$entry" 2>/dev/null || true)"
    if [[ -z "$resolved" ]]; then
      # macOS readlink lacks -f; walk symlinks manually
      resolved="$entry"
      while [[ -L "$resolved" ]]; do
        local target
        target="$(readlink "$resolved")"
        if [[ "$target" != /* ]]; then
          resolved="$(cd "$(dirname "$resolved")" && pwd)/$target"
        else
          resolved="$target"
        fi
      done
      resolved="$(cd "$(dirname "$resolved")" && pwd)/$(basename "$resolved")"
    fi
  else
    resolved="$(cd "$(dirname "$entry")" && pwd)/$(basename "$entry")"
  fi
  OL_RUNBOOK_ROOT="$(cd "$(dirname "$resolved")" && pwd)"
  CODING_AGENTS_DIR="${OL_RUNBOOK_ROOT}/coding-agents"
  MBTA_SCRIPT="$resolved"
  ENV_EXAMPLE="${CODING_AGENTS_DIR}/env.example"
  PROFILES_DIR="${CODING_AGENTS_DIR}/profiles"
}

mbta_validate_profile_name() {
  local name="$1"
  if [[ ! "$name" =~ ^[a-zA-Z0-9][a-zA-Z0-9_-]*$ ]]; then
    echo "error: invalid profile name '$name' (use letters, digits, _, -)" >&2
    return 1
  fi
}

# Resolve profile name → absolute env file path.
# default → coding-agents/.env; named → coding-agents/profiles/<name>.env
mbta_profile_file() {
  local profile="${1:-default}"
  mbta_validate_profile_name "$profile" || return 1
  if [[ "$profile" == "default" ]]; then
    echo "${CODING_AGENTS_DIR}/.env"
  else
    echo "${PROFILES_DIR}/${profile}.env"
  fi
}

# Ensure a profile env file exists (copy from env.example). chmod 600.
mbta_ensure_profile_file() {
  local file="$1"
  if [[ ! -f "$file" ]]; then
    mkdir -p "$(dirname "$file")"
    if [[ -f "$ENV_EXAMPLE" ]]; then
      cp "$ENV_EXAMPLE" "$file"
    else
      cat >"$file" <<'EOF'
# Subconscious API Gateway — coding agents config
GATEWAY_URL=
API_KEY=
MODEL=gw-glm-5.2
EOF
    fi
    chmod 600 "$file"
  fi
}

# Upsert KEY=VALUE in an env file, preserving other lines/comments.
mbta_upsert_env_key() {
  local file="$1"
  local key="$2"
  local value="$3"
  local tmp
  tmp="$(mktemp)"
  if [[ -f "$file" ]] && grep -qE "^${key}=" "$file"; then
    # shellcheck disable=SC2002
    awk -v k="$key" -v v="$value" '
      BEGIN { done = 0 }
      $0 ~ ("^" k "=") {
        print k "=" v
        done = 1
        next
      }
      { print }
      END { if (!done) print k "=" v }
    ' "$file" >"$tmp"
  else
    if [[ -f "$file" ]]; then
      cp "$file" "$tmp"
    else
      : >"$tmp"
    fi
    printf '%s=%s\n' "$key" "$value" >>"$tmp"
  fi
  mv "$tmp" "$file"
  chmod 600 "$file"
}

mbta_redact_api_key() {
  local key="$1"
  local len=${#key}
  if [[ $len -le 8 ]]; then
    echo "********"
  else
    echo "${key:0:4}…${key: -4}"
  fi
}

mbta_show_profile() {
  local file="$1"
  local profile="$2"
  local profile_flag=""
  if [[ "$profile" != "default" ]]; then
    profile_flag=" --profile $profile"
  fi
  if [[ ! -f "$file" ]]; then
    echo "profile: $profile (not configured)"
    echo "path:    $file"
    echo "hint:    mbta config${profile_flag} --gateway-url URL --api-key KEY"
    return 0
  fi
  # shellcheck disable=SC1090
  set -a
  # shellcheck source=/dev/null
  source "$file"
  set +a
  echo "profile: $profile"
  echo "path:    $file"
  echo "GATEWAY_URL=${GATEWAY_URL:-}"
  if [[ -n "${API_KEY:-}" ]]; then
    echo "API_KEY=$(mbta_redact_api_key "$API_KEY")"
  else
    echo "API_KEY="
  fi
  echo "MODEL=${MODEL:-}"
}

mbta_list_profiles() {
  echo "default  ${CODING_AGENTS_DIR}/.env$([ -f "${CODING_AGENTS_DIR}/.env" ] && echo "" || echo "  (missing)")"
  if [[ -d "$PROFILES_DIR" ]]; then
    local f name
    for f in "$PROFILES_DIR"/*.env; do
      [[ -e "$f" ]] || continue
      name="$(basename "$f" .env)"
      echo "$name  $f"
    done
  fi
}

# Canonical agent directory names.
mbta_resolve_agent() {
  case "$1" in
    cursor) echo "cursor" ;;
    copilot|vscode|vs-code) echo "copilot" ;;
    claude-code|claude) echo "claude-code" ;;
    codex) echo "codex" ;;
    opencode) echo "opencode" ;;
    pi) echo "pi" ;;
    *) return 1 ;;
  esac
}

mbta_agent_has_run_sh() {
  case "$1" in
    claude-code|codex|opencode) return 0 ;;
    *) return 1 ;;
  esac
}

mbta_agent_has_use() {
  case "$1" in
    claude-code|codex) return 0 ;;
    *) return 1 ;;
  esac
}
