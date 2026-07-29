#!/usr/bin/env bash
# Fail-open VS Code Copilot hook: client-side ensure + local Start→UPS drain + associate.
# Stdin: VS Code hook JSON. Stdout: permissive JSON for VS Code. Never blocks the agent.
#
# Docs: https://code.visualstudio.com/docs/copilot/customization/hooks
#
# Gateway events:
#   SessionStart / UserPromptSubmit (parent) -> conversation_ensure
#   SubagentStart -> push pending locally (no gateway call until UPS arms the child)
#   UserPromptSubmit while pending -> pop, ensure child with task_fp=hash(prompt)
#   SubagentStop / Stop -> conversation_associate by stored prompt_fp
#
# Local state: ~/.copilot/subconscious-corr-state.json (override with SUBCONSCIOUS_CORR_STATE)
# Concurrent hook invocations are serialized via mkdir lock (portable; no flock binary).

set -u

CONFIG="${SUBCONSCIOUS_HOOKS_ENV:-${HOME}/.copilot/subconscious-hooks.env}"
if [[ -f "$CONFIG" ]]; then
  # shellcheck disable=SC1090
  source "$CONFIG"
fi

GATEWAY_URL="${SUBCONSCIOUS_GATEWAY_URL:-}"
API_KEY="${SUBCONSCIOUS_API_KEY:-}"
STATE_FILE="${SUBCONSCIOUS_CORR_STATE:-${HOME}/.copilot/subconscious-corr-state.json}"
LOCK_DIR="${STATE_FILE}.lockdir"

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
PROMPT="$(printf '%s' "$INPUT" | jq -r '.prompt // empty' 2>/dev/null || true)"
CWD="$(printf '%s' "$INPUT" | jq -r '.cwd // empty' 2>/dev/null || true)"
WORKSPACE=""
if [[ -n "$CWD" ]]; then
  WORKSPACE="$(basename "$CWD")"
fi
AGENT_ID="$(printf '%s' "$INPUT" | jq -r '.agent_id // empty' 2>/dev/null || true)"

if [[ -z "$SESSION_ID" || -z "$HOOK_EVENT" ]]; then
  fail_open
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

now_epoch() {
  date +%s
}

ensure_state_file() {
  mkdir -p "$(dirname "$STATE_FILE")"
  if [[ ! -f "$STATE_FILE" ]]; then
    printf '%s\n' '{"sessions":{}}' >"$STATE_FILE"
  fi
}

# Portable exclusive lock (mkdir is atomic). Returns 0 on success.
lock_acquire() {
  ensure_state_file
  local i=0
  while ! mkdir "$LOCK_DIR" 2>/dev/null; do
    i=$((i + 1))
    if [[ "$i" -gt 40 ]]; then
      echo "subconscious hook: state lock busy" >&2
      return 1
    fi
    sleep 0.05
  done
  return 0
}

lock_release() {
  rmdir "$LOCK_DIR" 2>/dev/null || true
}

state_jq() {
  local tmp
  tmp="$(mktemp)"
  if ! jq "$@" "$STATE_FILE" >"$tmp" 2>/dev/null; then
    rm -f "$tmp"
    return 1
  fi
  mv "$tmp" "$STATE_FILE"
}

ensure_session_body() {
  local sid="$1"
  state_jq --arg s "$sid" '
    if (.sessions[$s] // null) == null then
      .sessions[$s] = {
        gw_conversation_id: null,
        parent_root_prompt_fp: null,
        pending_subagent_ids: [],
        children: {}
      }
    else . end
  '
}

post_hooks() {
  local payload="$1"
  local url="${GATEWAY_URL%/}/v1/agent-hooks"
  curl -sS -m 2 \
    -H "Authorization: Bearer ${API_KEY}" \
    -H "Content-Type: application/json" \
    -H "x-subconscious-client: copilot" \
    -d "$payload" \
    "$url" 2>/dev/null || true
}

associate() {
  local gw_id="$1"
  local prompt_fp="$2"
  local hook_event_name="$3"
  [[ -n "$gw_id" && -n "$prompt_fp" && "$prompt_fp" != "null" ]] || return 0
  local payload
  payload="$(jq -n \
    --arg event "conversation_associate" \
    --arg conversation_id "$gw_id" \
    --arg prompt_fp "$prompt_fp" \
    --arg hook_event_name "$hook_event_name" \
    '{
      event: $event,
      conversation_id: $conversation_id,
      prompt_fp: $prompt_fp,
      hook_event_name: $hook_event_name
    }'
  )"
  post_hooks "$payload" >/dev/null
}

case "$HOOK_EVENT" in
  SessionStart)
    if lock_acquire; then
      ensure_session_body "$SESSION_ID" || true
      lock_release
    fi
    PAYLOAD="$(jq -n \
      --arg event "conversation_ensure" \
      --arg conversation_id "$SESSION_ID" \
      --arg workspace "$WORKSPACE" \
      --arg hook_event_name "$HOOK_EVENT" \
      '{
        event: $event,
        conversation_id: $conversation_id,
        workspace: (if $workspace == "" then null else $workspace end),
        hook_event_name: $hook_event_name
      } | with_entries(select(.value != null))'
    )"
    RESP="$(post_hooks "$PAYLOAD")"
    GW_ID="$(printf '%s' "$RESP" | jq -r '.conversation_id // empty' 2>/dev/null || true)"
    if [[ -n "$GW_ID" ]] && lock_acquire; then
      state_jq --arg s "$SESSION_ID" --arg gw "$GW_ID" \
        '.sessions[$s].gw_conversation_id = $gw' || true
      lock_release
    fi
    ;;

  SubagentStart)
    if [[ -z "$AGENT_ID" ]]; then
      fail_open
    fi
    if lock_acquire; then
      ensure_session_body "$SESSION_ID" || true
      state_jq --arg s "$SESSION_ID" --arg a "$AGENT_ID" \
        '.sessions[$s].pending_subagent_ids += [$a]' || true
      lock_release
    fi
    ;;

  UserPromptSubmit)
    POPPED=""
    if lock_acquire; then
      ensure_session_body "$SESSION_ID" || true
      POPPED="$(jq -r --arg s "$SESSION_ID" \
        '(.sessions[$s].pending_subagent_ids // [])[0] // empty' "$STATE_FILE" 2>/dev/null || true)"
      if [[ -n "$POPPED" ]]; then
        state_jq --arg s "$SESSION_ID" \
          '.sessions[$s].pending_subagent_ids |= .[1:]' || true
      fi
      lock_release
    fi

    if [[ -n "$POPPED" ]]; then
      if [[ -n "$PROMPT" ]]; then
        TASK_FP="$(sha256_hex "$(normalize_prompt "$PROMPT")")"
      else
        TASK_FP="$(sha256_hex "$POPPED")"
      fi
      PAYLOAD="$(jq -n \
        --arg event "conversation_ensure" \
        --arg conversation_id "$TASK_FP" \
        --arg parent_conversation_id "$SESSION_ID" \
        --arg prompt_fp "$TASK_FP" \
        --arg workspace "$WORKSPACE" \
        --arg hook_event_name "$HOOK_EVENT" \
        '{
          event: $event,
          conversation_id: $conversation_id,
          parent_conversation_id: $parent_conversation_id,
          prompt_fp: $prompt_fp,
          workspace: (if $workspace == "" then null else $workspace end),
          hook_event_name: $hook_event_name
        } | with_entries(select(.value != null))'
      )"
      RESP="$(post_hooks "$PAYLOAD")"
      GW_ID="$(printf '%s' "$RESP" | jq -r '.conversation_id // empty' 2>/dev/null || true)"
      if [[ -n "$GW_ID" ]] && lock_acquire; then
        state_jq --arg s "$SESSION_ID" --arg a "$POPPED" --arg gw "$GW_ID" --arg fp "$TASK_FP" \
          --argjson ts "$(now_epoch)" \
          '.sessions[$s].children[$a] = {
            gw_conversation_id: $gw,
            task_fp: $fp,
            armed_at: $ts
          }' || true
        lock_release
      fi
    else
      PROMPT_FP=""
      if [[ -n "$PROMPT" ]]; then
        PROMPT_FP="$(sha256_hex "$(normalize_prompt "$PROMPT")")"
      fi
      PAYLOAD="$(jq -n \
        --arg event "conversation_ensure" \
        --arg conversation_id "$SESSION_ID" \
        --arg prompt_fp "$PROMPT_FP" \
        --arg workspace "$WORKSPACE" \
        --arg hook_event_name "$HOOK_EVENT" \
        '{
          event: $event,
          conversation_id: $conversation_id,
          prompt_fp: (if $prompt_fp == "" then null else $prompt_fp end),
          workspace: (if $workspace == "" then null else $workspace end),
          hook_event_name: $hook_event_name
        } | with_entries(select(.value != null))'
      )"
      RESP="$(post_hooks "$PAYLOAD")"
      GW_ID="$(printf '%s' "$RESP" | jq -r '.conversation_id // empty' 2>/dev/null || true)"
      if lock_acquire; then
        ensure_session_body "$SESSION_ID" || true
        state_jq --arg s "$SESSION_ID" --arg gw "$GW_ID" --arg fp "$PROMPT_FP" '
          .sessions[$s].gw_conversation_id =
            (if $gw == "" then .sessions[$s].gw_conversation_id else $gw end)
          | .sessions[$s].parent_root_prompt_fp =
            (if $fp == "" then .sessions[$s].parent_root_prompt_fp else $fp end)
        ' || true
        lock_release
      fi
    fi
    ;;

  SubagentStop)
    if [[ -z "$AGENT_ID" ]]; then
      fail_open
    fi
    CHILD=""
    if lock_acquire; then
      ensure_session_body "$SESSION_ID" || true
      CHILD="$(jq -c --arg s "$SESSION_ID" --arg a "$AGENT_ID" \
        '.sessions[$s].children[$a] // empty' "$STATE_FILE" 2>/dev/null || true)"
      if [[ -n "$CHILD" ]]; then
        state_jq --arg s "$SESSION_ID" --arg a "$AGENT_ID" \
          'del(.sessions[$s].children[$a])' || true
      fi
      lock_release
    fi
    if [[ -n "$CHILD" ]]; then
      GW_ID="$(printf '%s' "$CHILD" | jq -r '.gw_conversation_id // empty')"
      TASK_FP="$(printf '%s' "$CHILD" | jq -r '.task_fp // empty')"
      associate "$GW_ID" "$TASK_FP" "$HOOK_EVENT"
    fi
    ;;

  Stop)
    SNAP=""
    if lock_acquire; then
      ensure_session_body "$SESSION_ID" || true
      SNAP="$(jq -c --arg s "$SESSION_ID" '{
        gw: (.sessions[$s].gw_conversation_id // null),
        fp: (.sessions[$s].parent_root_prompt_fp // null),
        children: (.sessions[$s].children // {})
      }' "$STATE_FILE" 2>/dev/null || true)"
      state_jq --arg s "$SESSION_ID" '.sessions[$s].children = {}' || true
      lock_release
    fi
    GW_ID="$(printf '%s' "$SNAP" | jq -r '.gw // empty')"
    PROMPT_FP="$(printf '%s' "$SNAP" | jq -r '.fp // empty')"
    associate "$GW_ID" "$PROMPT_FP" "$HOOK_EVENT"
    # Safety net: associate any children that missed SubagentStop.
    while IFS= read -r child; do
      [[ -n "$child" ]] || continue
      c_gw="$(printf '%s' "$child" | jq -r '.gw_conversation_id // empty')"
      c_fp="$(printf '%s' "$child" | jq -r '.task_fp // empty')"
      associate "$c_gw" "$c_fp" "Stop"
    done < <(printf '%s' "$SNAP" | jq -c '.children // {} | .[]' 2>/dev/null || true)
    ;;

  *)
    fail_open
    ;;
esac

fail_open
