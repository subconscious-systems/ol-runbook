#!/usr/bin/env bash
# Shared implementation used by each profile-specific weights.sh wrapper.
set -euo pipefail

HF_CLI_VENV="${HF_CLI_VENV:-${XDG_DATA_HOME:-${HOME}/.local/share}/subconscious/hf-cli}"

log() { printf '[weights] %s\n' "$*"; }
die() { printf '[weights] ERROR: %s\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

usage() {
  cat <<'EOF'
Usage: _weights.sh <profile-name> <hf-repo> <target-path> [<hf-repo> <target-path> ...]

Shared implementation for profile-specific weights.sh wrappers. Prompts for a
Hugging Face token and download root, then downloads every repository declared
by the wrapper. The token is neither echoed nor placed on the command line.
EOF
}

[[ ${1:-} != -h && ${1:-} != --help ]] || { usage; exit 0; }
[[ $# -ge 3 && $((($# - 1) % 2)) -eq 0 ]] || { usage >&2; exit 2; }

PROFILE_NAME="$1"
shift

DOWNLOAD_ROWS=()
while (($#)); do
  repo="$1"
  target="$2"
  [[ -n "$repo" && "$target" == /* ]] || die "invalid repository or target path for $PROFILE_NAME"
  DOWNLOAD_ROWS+=("${repo}"$'\t'"${target}")
  shift 2
done

DEFAULT_ROOT=""
for row in "${DOWNLOAD_ROWS[@]}"; do
  IFS=$'\t' read -r repo target <<<"$row"
  target_root="$(dirname "$target")"
  if [[ -z "$DEFAULT_ROOT" ]]; then
    DEFAULT_ROOT="$target_root"
  elif [[ "$DEFAULT_ROOT" != "$target_root" ]]; then
    DEFAULT_ROOT=""
  fi
done

[[ -t 0 ]] || die "run this command in an interactive terminal"
read -r -s -p "Hugging Face token: " HF_TOKEN_INPUT
printf '\n'
[[ -n "$HF_TOKEN_INPUT" ]] || die "a Hugging Face token is required"
trap 'unset HF_TOKEN_INPUT HF_TOKEN' EXIT

if [[ -n "$DEFAULT_ROOT" ]]; then
  read -r -p "Download root [${DEFAULT_ROOT}]: " DOWNLOAD_ROOT
  DOWNLOAD_ROOT="${DOWNLOAD_ROOT:-$DEFAULT_ROOT}"
else
  read -r -p "Download root: " DOWNLOAD_ROOT
fi
[[ "$DOWNLOAD_ROOT" == /* ]] || die "download root must be an absolute path"
DOWNLOAD_ROOT="${DOWNLOAD_ROOT%/}"

log "profile: $PROFILE_NAME"
for row in "${DOWNLOAD_ROWS[@]}"; do
  IFS=$'\t' read -r repo target <<<"$row"
  printf '  %s -> %s/%s\n' "$repo" "$DOWNLOAD_ROOT" "$(basename "$target")"
done
read -r -p "Continue? [y/N]: " CONFIRM
[[ "$CONFIRM" =~ ^[Yy]$ ]] || die "cancelled"

if ! mkdir -p "$DOWNLOAD_ROOT"; then
  die "cannot create $DOWNLOAD_ROOT; create it with the correct ownership first"
fi
[[ -w "$DOWNLOAD_ROOT" ]] || die "download root is not writable: $DOWNLOAD_ROOT"

if have hf; then
  HF_CLI_BIN="$(command -v hf)"
else
  have python3 || die "python3 is required; run the profile installer first"
  log "installing the Hugging Face CLI in $HF_CLI_VENV"
  python3 -m venv "$HF_CLI_VENV" ||
    die "could not create a Python venv; run the profile installer first"
  "$HF_CLI_VENV/bin/pip" install --upgrade huggingface_hub
  HF_CLI_BIN="$HF_CLI_VENV/bin/hf"
  [[ -x "$HF_CLI_BIN" ]] || die "Hugging Face CLI installation did not create $HF_CLI_BIN"
fi

export HF_TOKEN="$HF_TOKEN_INPUT"
for row in "${DOWNLOAD_ROWS[@]}"; do
  IFS=$'\t' read -r repo target <<<"$row"
  destination="$DOWNLOAD_ROOT/$(basename "$target")"
  log "downloading $repo to $destination"
  "$HF_CLI_BIN" download "$repo" --local-dir "$destination"
done

unset HF_TOKEN_INPUT HF_TOKEN
trap - EXIT
log "all profile weights are ready under $DOWNLOAD_ROOT"
