#!/usr/bin/env bash
# Fail-open Cursor hook: announce turn_open / turn_heartbeat / turn_close to the gateway.
# Stdin: Cursor hook JSON. Stdout: permissive JSON for Cursor. Never blocks the agent.

set -u

CONFIG="${SUBCONSCIOUS_HOOKS_ENV:-${HOME}/.cursor/subconscious-hooks.env}"
if [[ -f "$CONFIG" ]]; then
  # shellcheck disable=SC1090
  source "$CONFIG"
fi

GATEWAY_URL="${SUBCONSCIOUS_GATEWAY_URL:-}"
API_KEY="${SUBCONSCIOUS_API_KEY:-}"

fail_open() {
  # beforeSubmitPrompt expects continue; other hooks accept empty / allow.
  printf '%s\n' '{"continue":true,"permission":"allow"}'
  exit 0
}

if [[ -z "$GATEWAY_URL" || -z "$API_KEY" ]]; then
  echo "subconscious hook: missing SUBCONSCIOUS_GATEWAY_URL or SUBCONSCIOUS_API_KEY" >&2
  fail_open
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "subconscious hook: jq is required" >&2
  fail_open
fi
if ! command -v curl >/dev/null 2>&1; then
  echo "subconscious hook: curl is required" >&2
  fail_open
fi
if ! command -v openssl >/dev/null 2>&1 && ! command -v shasum >/dev/null 2>&1; then
  echo "subconscious hook: openssl or shasum is required" >&2
  fail_open
fi

INPUT="$(cat || true)"
if [[ -z "$INPUT" ]]; then
  fail_open
fi

HOOK_EVENT="$(printf '%s' "$INPUT" | jq -r '.hook_event_name // empty' 2>/dev/null || true)"
CONVERSATION_ID="$(printf '%s' "$INPUT" | jq -r '.conversation_id // .session_id // empty' 2>/dev/null || true)"
GENERATION_ID="$(printf '%s' "$INPUT" | jq -r '.generation_id // empty' 2>/dev/null || true)"
MODEL="$(printf '%s' "$INPUT" | jq -r '.model // empty' 2>/dev/null || true)"
PROMPT="$(printf '%s' "$INPUT" | jq -r '.prompt // empty' 2>/dev/null || true)"
RESPONSE_TEXT="$(printf '%s' "$INPUT" | jq -r '.text // empty' 2>/dev/null || true)"
WORKSPACE="$(printf '%s' "$INPUT" | jq -r '(.workspace_roots // [])[0] // empty' 2>/dev/null || true)"
if [[ -n "$WORKSPACE" ]]; then
  WORKSPACE="$(basename "$WORKSPACE")"
fi

if [[ -z "$CONVERSATION_ID" || -z "$GENERATION_ID" ]]; then
  fail_open
fi

# Must match observability::normalize_prompt_for_fingerprint + prompt_fingerprint.
normalize_prompt() {
  # CRLF -> LF, trim leading/trailing whitespace
  printf '%s' "$1" | tr -d '\r' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'
}

sha256_hex() {
  local data="$1"
  if command -v openssl >/dev/null 2>&1; then
    printf '%s' "$data" | openssl dgst -sha256 -hex 2>/dev/null | awk '{print $NF}'
  else
    printf '%s' "$data" | shasum -a 256 | awk '{print $1}'
  fi
}

EVENT=""
PROMPT_FP=""
RESPONSE_FP=""
case "$HOOK_EVENT" in
  beforeSubmitPrompt)
    EVENT="turn_open"
    PROMPT_FP="$(sha256_hex "$(normalize_prompt "$PROMPT")")"
    ;;
  afterAgentResponse)
    EVENT="turn_heartbeat"
    if [[ -n "$RESPONSE_TEXT" ]]; then
      RESPONSE_FP="$(sha256_hex "$(normalize_prompt "$RESPONSE_TEXT")")"
    fi
    ;;
  stop)
    EVENT="turn_close"
    if [[ -n "$RESPONSE_TEXT" ]]; then
      RESPONSE_FP="$(sha256_hex "$(normalize_prompt "$RESPONSE_TEXT")")"
    fi
    ;;
  *)
    fail_open
    ;;
esac

PAYLOAD="$(jq -n \
  --arg event "$EVENT" \
  --arg conversation_id "$CONVERSATION_ID" \
  --arg generation_id "$GENERATION_ID" \
  --arg prompt_fp "$PROMPT_FP" \
  --arg response_fp "$RESPONSE_FP" \
  --arg model "$MODEL" \
  --arg workspace "$WORKSPACE" \
  --arg hook_event_name "$HOOK_EVENT" \
  '{
    event: $event,
    conversation_id: $conversation_id,
    generation_id: $generation_id,
    prompt_fp: (if $prompt_fp == "" then null else $prompt_fp end),
    response_fp: (if $response_fp == "" then null else $response_fp end),
    model: (if $model == "" then null else $model end),
    workspace: (if $workspace == "" then null else $workspace end),
    hook_event_name: (if $hook_event_name == "" then null else $hook_event_name end)
  } | with_entries(select(.value != null))'
)"

URL="${GATEWAY_URL%/}/v1/agent-hooks"
curl -sS -m 2 \
  -H "Authorization: Bearer ${API_KEY}" \
  -H "Content-Type: application/json" \
  -d "$PAYLOAD" \
  "$URL" >/dev/null 2>&1 || true

fail_open
