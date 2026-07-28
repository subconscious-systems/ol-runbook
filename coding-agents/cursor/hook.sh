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
# Subagent (Task tool) lifecycle fields. Cursor's subagentStart carries
# parent_conversation_id explicitly; subagentStop does not, but the same
# parent id is required to link the child turn_close to the parent conversation.
SUBAGENT_ID="$(printf '%s' "$INPUT" | jq -r '.subagent_id // empty' 2>/dev/null || true)"
SUBAGENT_PARENT_CONV="$(printf '%s' "$INPUT" | jq -r '.parent_conversation_id // empty' 2>/dev/null || true)"

# PARENT_CONVERSATION_ID is only set for subagent events; initialize empty here
# so the jq payload build always has a value (set -u safe). The subagent guard
# below overwrites it for subagentStart/subagentStop.
PARENT_CONVERSATION_ID=""

# Subagent events: the subagent is its own conversation window. Cursor's payload
# gives us the parent's conversation_id (base field) and parent_conversation_id
# (explicit), plus subagent_id as the unique subagent handle. We use subagent_id
# as both the child conversation_id and the generation_id so the gateway creates
# a distinct child conversation row linked to the parent via parent_conversation_id.
if [[ "$HOOK_EVENT" == "subagentStart" ]]; then
  # subagentStart carries parent_conversation_id; we need it to link the child.
  if [[ -z "$SUBAGENT_ID" || -z "$SUBAGENT_PARENT_CONV" ]]; then
    fail_open
  fi
  PARENT_CONVERSATION_ID="$SUBAGENT_PARENT_CONV"
  CONVERSATION_ID="$SUBAGENT_ID"
  GENERATION_ID="$SUBAGENT_ID"
elif [[ "$HOOK_EVENT" == "subagentStop" ]]; then
  # subagentStop does not carry parent_conversation_id; we only need the
  # subagent handle to close its generation window.
  if [[ -z "$SUBAGENT_ID" ]]; then
    fail_open
  fi
  CONVERSATION_ID="$SUBAGENT_ID"
  GENERATION_ID="$SUBAGENT_ID"
else
  if [[ -z "$CONVERSATION_ID" || -z "$GENERATION_ID" ]]; then
    fail_open
  fi
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
  subagentStart)
    EVENT="turn_open"
    # No user prompt fingerprint for a subagent spawn; hash the task description
    # so the gateway's turn_open prompt_fp requirement is satisfied. The gateway
    # soft-binds later LLM requests that share this fingerprint, so a subagent
    # using its own task text as the first user message will correlate.
    SUBAGENT_TASK="$(printf '%s' "$INPUT" | jq -r '.task // empty' 2>/dev/null || true)"
    if [[ -n "$SUBAGENT_TASK" ]]; then
      PROMPT_FP="$(sha256_hex "$(normalize_prompt "$SUBAGENT_TASK")")"
    else
      PROMPT_FP="$(sha256_hex "$SUBAGENT_ID")"
    fi
    ;;
  subagentStop)
    EVENT="turn_close"
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
  --arg parent_conversation_id "$PARENT_CONVERSATION_ID" \
  '{
    event: $event,
    conversation_id: $conversation_id,
    generation_id: $generation_id,
    prompt_fp: (if $prompt_fp == "" then null else $prompt_fp end),
    response_fp: (if $response_fp == "" then null else $response_fp end),
    model: (if $model == "" then null else $model end),
    workspace: (if $workspace == "" then null else $workspace end),
    hook_event_name: (if $hook_event_name == "" then null else $hook_event_name end),
    parent_conversation_id: (if $parent_conversation_id == "" then null else $parent_conversation_id end)
  } | with_entries(select(.value != null))'
)"

URL="${GATEWAY_URL%/}/v1/agent-hooks"
curl -sS -m 2 \
  -H "Authorization: Bearer ${API_KEY}" \
  -H "Content-Type: application/json" \
  -d "$PAYLOAD" \
  "$URL" >/dev/null 2>&1 || true

fail_open
