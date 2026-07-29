#!/usr/bin/env bash
# Fail-open Cursor hook: client-side conversation ensure + post-hoc associate.
# Stdin: Cursor hook JSON. Stdout: permissive JSON for Cursor. Never blocks the agent.
#
# Docs: https://cursor.com/docs/agent/hooks
#
# Gateway events:
#   subagentStart -> push pending locally (no gateway call until UPS arms the child)
#   beforeSubmitPrompt (parent) -> conversation_ensure
#   beforeSubmitPrompt while pending -> pop, ensure child with task_fp=hash(prompt)
#   afterAgentResponse / stop / subagentStop -> conversation_associate by stored prompt_fp
#
# Local state: ~/.cursor/subconscious-corr-state.json (override with SUBCONSCIOUS_CORR_STATE)
# Concurrent hook invocations are serialized via mkdir lock (portable; no flock binary).

set -u

CONFIG="${SUBCONSCIOUS_HOOKS_ENV:-${HOME}/.cursor/subconscious-hooks.env}"
if [[ -f "$CONFIG" ]]; then
  # shellcheck disable=SC1090
  source "$CONFIG"
fi

GATEWAY_URL="${SUBCONSCIOUS_GATEWAY_URL:-}"
API_KEY="${SUBCONSCIOUS_API_KEY:-}"
STATE_FILE="${SUBCONSCIOUS_CORR_STATE:-${HOME}/.cursor/subconscious-corr-state.json}"
LOCK_DIR="${STATE_FILE}.lockdir"

fail_open() {
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
MODEL="$(printf '%s' "$INPUT" | jq -r '.model // empty' 2>/dev/null || true)"
PROMPT="$(printf '%s' "$INPUT" | jq -r '.prompt // empty' 2>/dev/null || true)"
WORKSPACE="$(printf '%s' "$INPUT" | jq -r '(.workspace_roots // [])[0] // empty' 2>/dev/null || true)"
if [[ -n "$WORKSPACE" ]]; then
  WORKSPACE="$(basename "$WORKSPACE")"
fi
SUBAGENT_ID="$(printf '%s' "$INPUT" | jq -r '.subagent_id // empty' 2>/dev/null || true)"
SUBAGENT_PARENT_CONV="$(printf '%s' "$INPUT" | jq -r '.parent_conversation_id // empty' 2>/dev/null || true)"

# Fire log: append one line per hook invocation so we can audit exactly when
# hooks fire (e.g. whether Cursor fires any hook when you click "build" after the
# plan + build flow). Override the path with SUBCONSCIOUS_HOOK_LOG.
HOOK_LOG="${SUBCONSCIOUS_HOOK_LOG:-${HOME}/.cursor/subconscious-hook.log}"
PROMPT_SNIP="$(printf '%s' "$PROMPT" | head -c 200 | tr '\n' ' ')"
{
  printf '%s event=%s conv=%s subagent=%s parent=%s model=%s workspace=%s prompt_len=%s prompt="%s"\n' \
    "$(date '+%Y-%m-%dT%H:%M:%S%z')" \
    "${HOOK_EVENT:-?}" \
    "${CONVERSATION_ID:-}" \
    "${SUBAGENT_ID:-}" \
    "${SUBAGENT_PARENT_CONV:-}" \
    "${MODEL:-}" \
    "${WORKSPACE:-}" \
    "${#PROMPT}" \
    "$PROMPT_SNIP"
} >>"$HOOK_LOG" 2>/dev/null || true

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
    printf '%s\n' '{"conversations":{}}' >"$STATE_FILE"
  fi
}

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

ensure_conv_body() {
  local cid="$1"
  state_jq --arg c "$cid" '
    if (.conversations[$c] // null) == null then
      .conversations[$c] = {
        gw_conversation_id: null,
        updated_at: 0,
        last_prompt_fp: null,
        pending_subagent_ids: [],
        children: {}
      }
    else
      .conversations[$c].pending_subagent_ids //= []
      | .conversations[$c].children //= {}
    end
  '
}

post_hooks() {
  local payload="$1"
  local url="${GATEWAY_URL%/}/v1/agent-hooks"
  curl -sS -m 2 \
    -H "Authorization: Bearer ${API_KEY}" \
    -H "Content-Type: application/json" \
    -H "x-subconscious-client: cursor" \
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
  beforeSubmitPrompt)
    if [[ -z "$CONVERSATION_ID" ]]; then
      fail_open
    fi

    POPPED=""
    if lock_acquire; then
      ensure_conv_body "$CONVERSATION_ID" || true
      POPPED="$(jq -r --arg c "$CONVERSATION_ID" \
        '(.conversations[$c].pending_subagent_ids // [])[0] // empty' "$STATE_FILE" 2>/dev/null || true)"
      if [[ -n "$POPPED" ]]; then
        state_jq --arg c "$CONVERSATION_ID" --argjson now "$(now_epoch)" \
          '.conversations[$c].pending_subagent_ids |= .[1:]
           | .conversations[$c].updated_at = $now
           | .conversations |= with_entries(select(.value.updated_at > ($now - 3600)))' || true
      fi
      lock_release
    fi

    if [[ -n "$POPPED" ]]; then
      # This UPS arms a pending subagent. Hash the actual prompt content so
      # the fingerprint matches what the gateway computes from the LLM request.
      if [[ -n "$PROMPT" ]]; then
        TASK_FP="$(sha256_hex "$(normalize_prompt "$PROMPT")")"
      else
        TASK_FP="$(sha256_hex "$POPPED")"
      fi
      PAYLOAD="$(jq -n \
        --arg event "conversation_ensure" \
        --arg conversation_id "$POPPED" \
        --arg parent_conversation_id "$CONVERSATION_ID" \
        --arg prompt_fp "$TASK_FP" \
        --arg model "$MODEL" \
        --arg workspace "$WORKSPACE" \
        --arg hook_event_name "$HOOK_EVENT" \
        '{
          event: $event,
          conversation_id: $conversation_id,
          parent_conversation_id: $parent_conversation_id,
          prompt_fp: $prompt_fp,
          model: (if $model == "" then null else $model end),
          workspace: (if $workspace == "" then null else $workspace end),
          hook_event_name: $hook_event_name
        } | with_entries(select(.value != null))'
      )"
      RESP="$(post_hooks "$PAYLOAD")"
      GW_ID="$(printf '%s' "$RESP" | jq -r '.conversation_id // empty' 2>/dev/null || true)"
      if [[ -n "$GW_ID" ]] && lock_acquire; then
        state_jq --arg c "$CONVERSATION_ID" --arg a "$POPPED" \
          --arg gw "$GW_ID" --arg fp "$TASK_FP" \
          --argjson now "$(now_epoch)" \
          '.conversations[$c].children[$a] = {
            gw_conversation_id: $gw,
            task_fp: $fp,
            armed_at: $now
          }
          | .conversations[$c].updated_at = $now
          | .conversations |= with_entries(select(.value.updated_at > ($now - 3600)))' || true
        lock_release
      fi
    else
      PROMPT_FP=""
      if [[ -n "$PROMPT" ]]; then
        PROMPT_FP="$(sha256_hex "$(normalize_prompt "$PROMPT")")"
      fi
      PAYLOAD="$(jq -n \
        --arg event "conversation_ensure" \
        --arg conversation_id "$CONVERSATION_ID" \
        --arg prompt_fp "$PROMPT_FP" \
        --arg model "$MODEL" \
        --arg workspace "$WORKSPACE" \
        --arg hook_event_name "$HOOK_EVENT" \
        '{
          event: $event,
          conversation_id: $conversation_id,
          prompt_fp: (if $prompt_fp == "" then null else $prompt_fp end),
          model: (if $model == "" then null else $model end),
          workspace: (if $workspace == "" then null else $workspace end),
          hook_event_name: $hook_event_name
        } | with_entries(select(.value != null))'
      )"
      RESP="$(post_hooks "$PAYLOAD")"
      GW_ID="$(printf '%s' "$RESP" | jq -r '.conversation_id // empty' 2>/dev/null || true)"
      if lock_acquire; then
        ensure_conv_body "$CONVERSATION_ID" || true
        state_jq --arg c "$CONVERSATION_ID" --arg gw "$GW_ID" --arg fp "$PROMPT_FP" \
          --argjson now "$(now_epoch)" '
          .conversations[$c].gw_conversation_id =
            (if $gw == "" then .conversations[$c].gw_conversation_id else $gw end)
          | .conversations[$c].last_prompt_fp =
            (if $fp == "" then .conversations[$c].last_prompt_fp else $fp end)
          | .conversations[$c].updated_at = $now
          | .conversations |= with_entries(select(.value.updated_at > ($now - 3600)))
        ' || true
        lock_release
      fi
    fi
    ;;

  afterAgentResponse|stop)
    if [[ -z "$CONVERSATION_ID" ]]; then
      fail_open
    fi
    CONV_JSON=""
    if lock_acquire; then
      CONV_JSON="$(jq -c --arg c "$CONVERSATION_ID" \
        '.conversations[$c] // empty' "$STATE_FILE" 2>/dev/null || true)"
      lock_release
    fi
    if [[ -n "$CONV_JSON" ]]; then
      GW_ID="$(printf '%s' "$CONV_JSON" | jq -r '.gw_conversation_id // empty')"
      PROMPT_FP="$(printf '%s' "$CONV_JSON" | jq -r '.last_prompt_fp // empty')"
      associate "$GW_ID" "$PROMPT_FP" "$HOOK_EVENT"
    fi

    if [[ "$HOOK_EVENT" == "stop" && -n "$CONV_JSON" ]]; then
      while IFS= read -r child; do
        [[ -n "$child" ]] || continue
        c_gw="$(printf '%s' "$child" | jq -r '.gw_conversation_id // empty')"
        c_fp="$(printf '%s' "$child" | jq -r '.task_fp // empty')"
        associate "$c_gw" "$c_fp" "stop"
      done < <(printf '%s' "$CONV_JSON" | jq -c '.children // {} | .[]' 2>/dev/null || true)
      if lock_acquire; then
        state_jq --arg c "$CONVERSATION_ID" --argjson now "$(now_epoch)" \
          '.conversations[$c].children = {}
           | .conversations[$c].updated_at = $now
           | .conversations |= with_entries(select(.value.updated_at > ($now - 3600)))' || true
        lock_release
      fi
    fi
    ;;

  subagentStart)
    if [[ -z "$SUBAGENT_ID" || -z "$SUBAGENT_PARENT_CONV" ]]; then
      fail_open
    fi
    if lock_acquire; then
      ensure_conv_body "$SUBAGENT_PARENT_CONV" || true
      state_jq --arg c "$SUBAGENT_PARENT_CONV" --arg a "$SUBAGENT_ID" \
        --argjson now "$(now_epoch)" \
        '.conversations[$c].pending_subagent_ids += [$a]
         | .conversations[$c].updated_at = $now
         | .conversations |= with_entries(select(.value.updated_at > ($now - 3600)))' || true
      lock_release
    fi
    ;;

  subagentStop)
    if [[ -z "$SUBAGENT_ID" ]]; then
      fail_open
    fi
    CHILD=""
    if lock_acquire; then
      CHILD="$(jq -c --arg c "$CONVERSATION_ID" --arg a "$SUBAGENT_ID" \
        '.conversations[$c].children[$a] // empty' "$STATE_FILE" 2>/dev/null || true)"
      if [[ -n "$CHILD" ]]; then
        state_jq --arg c "$CONVERSATION_ID" --arg a "$SUBAGENT_ID" \
          --argjson now "$(now_epoch)" \
          'del(.conversations[$c].children[$a])
           | .conversations[$c].updated_at = $now
           | .conversations |= with_entries(select(.value.updated_at > ($now - 3600)))' || true
      fi
      lock_release
    fi
    if [[ -n "$CHILD" ]]; then
      GW_ID="$(printf '%s' "$CHILD" | jq -r '.gw_conversation_id // empty')"
      TASK_FP="$(printf '%s' "$CHILD" | jq -r '.task_fp // empty')"
      associate "$GW_ID" "$TASK_FP" "$HOOK_EVENT"
    fi
    ;;

  *)
    fail_open
    ;;
esac

fail_open
