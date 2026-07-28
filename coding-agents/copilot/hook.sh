#!/usr/bin/env bash
# Fail-open VS Code Copilot hook: announce turn_open / turn_close to the gateway.
# Stdin: VS Code hook JSON. Stdout: permissive JSON for VS Code. Never blocks the agent.
#
# VS Code hook events -> gateway events:
#   SessionStart      -> turn_open  (no prompt; fingerprint the session_id)
#   UserPromptSubmit  -> turn_open  (fingerprint the prompt)
#   Stop              -> turn_close
#   SubagentStart     -> turn_open  (child conversation, parent = session_id)
#   SubagentStop      -> turn_close (child conversation)
#
# VS Code has no afterAgentResponse equivalent, so there is no turn_heartbeat.

set -u

CONFIG="${SUBCONSCIOUS_HOOKS_ENV:-${HOME}/.copilot/subconscious-hooks.env}"
if [[ -f "$CONFIG" ]]; then
  # shellcheck disable=SC1090
  source "$CONFIG"
fi

GATEWAY_URL="${SUBCONSCIOUS_GATEWAY_URL:-}"
API_KEY="${SUBCONSCIOUS_API_KEY:-}"

fail_open() {
  printf '%s\n' '{"continue":true}'
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
SESSION_ID="$(printf '%s' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null || true)"
TIMESTAMP="$(printf '%s' "$INPUT" | jq -r '.timestamp // empty' 2>/dev/null || true)"
PROMPT="$(printf '%s' "$INPUT" | jq -r '.prompt // empty' 2>/dev/null || true)"
CWD="$(printf '%s' "$INPUT" | jq -r '.cwd // empty' 2>/dev/null || true)"
WORKSPACE=""
if [[ -n "$CWD" ]]; then
  WORKSPACE="$(basename "$CWD")"
fi

# Subagent fields.
AGENT_ID="$(printf '%s' "$INPUT" | jq -r '.agent_id // empty' 2>/dev/null || true)"
AGENT_TYPE="$(printf '%s' "$INPUT" | jq -r '.agent_type // empty' 2>/dev/null || true)"

if [[ -z "$SESSION_ID" || -z "$HOOK_EVENT" ]]; then
  fail_open
fi

# Derive a generation_id from session_id + timestamp so each prompt within a
# session gets a distinct generation window. VS Code does not provide a
# native generation_id.
GENERATION_ID="${SESSION_ID}:${TIMESTAMP}"

# PARENT_CONVERSATION_ID is only set for subagent events.
PARENT_CONVERSATION_ID=""

# Subagent events: the subagent is its own conversation window. VS Code gives
# us agent_id as the unique subagent handle and session_id as the parent
# session. We use agent_id as the child conversation_id and session_id as
# the parent_conversation_id so the gateway links the child to the parent.
if [[ "$HOOK_EVENT" == "SubagentStart" ]]; then
  if [[ -z "$AGENT_ID" ]]; then
    fail_open
  fi
  PARENT_CONVERSATION_ID="$SESSION_ID"
  CONVERSATION_ID="$AGENT_ID"
  GENERATION_ID="${AGENT_ID}:${TIMESTAMP}"
elif [[ "$HOOK_EVENT" == "SubagentStop" ]]; then
  if [[ -z "$AGENT_ID" ]]; then
    fail_open
  fi
  PARENT_CONVERSATION_ID="$SESSION_ID"
  CONVERSATION_ID="$AGENT_ID"
  GENERATION_ID="${AGENT_ID}:${TIMESTAMP}"
else
  CONVERSATION_ID="$SESSION_ID"
fi

# Must match observability::normalize_prompt_for_fingerprint + prompt_fingerprint.
normalize_prompt() {
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
case "$HOOK_EVENT" in
  SessionStart)
    EVENT="turn_open"
    # SessionStart has no prompt field; fingerprint the session_id so the
    # gateway's turn_open prompt_fp requirement is satisfied. The first
    # UserPromptSubmit will carry the actual prompt fingerprint for soft-bind.
    PROMPT_FP="$(sha256_hex "$(normalize_prompt "$SESSION_ID")")"
    ;;
  UserPromptSubmit)
    EVENT="turn_open"
    if [[ -n "$PROMPT" ]]; then
      PROMPT_FP="$(sha256_hex "$(normalize_prompt "$PROMPT")")"
    else
      PROMPT_FP="$(sha256_hex "$(normalize_prompt "$SESSION_ID")")"
    fi
    ;;
  Stop)
    EVENT="turn_close"
    ;;
  SubagentStart)
    EVENT="turn_open"
    # Fingerprint the agent_type + task context so the subagent's first LLM
    # request can soft-bind. VS Code does not carry a task field, so hash the
    # agent_type as a stable proxy.
    if [[ -n "$AGENT_TYPE" ]]; then
      PROMPT_FP="$(sha256_hex "$(normalize_prompt "$AGENT_TYPE")")"
    else
      PROMPT_FP="$(sha256_hex "$AGENT_ID")"
    fi
    ;;
  SubagentStop)
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
  --arg workspace "$WORKSPACE" \
  --arg hook_event_name "$HOOK_EVENT" \
  --arg parent_conversation_id "$PARENT_CONVERSATION_ID" \
  '{
    event: $event,
    conversation_id: $conversation_id,
    generation_id: $generation_id,
    prompt_fp: (if $prompt_fp == "" then null else $prompt_fp end),
    workspace: (if $workspace == "" then null else $workspace end),
    hook_event_name: (if $hook_event_name == "" then null else $hook_event_name end),
    parent_conversation_id: (if $parent_conversation_id == "" then null else $parent_conversation_id end)
  } | with_entries(select(.value != null))'
)"

URL="${GATEWAY_URL%/}/v1/agent-hooks"
curl -sS -m 2 \
  -H "Authorization: Bearer ${API_KEY}" \
  -H "Content-Type: application/json" \
  -H "x-subconscious-client: copilot" \
  -d "$PAYLOAD" \
  "$URL" >/dev/null 2>&1 || true

fail_open
