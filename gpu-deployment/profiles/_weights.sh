#!/usr/bin/env bash
# Shared implementation used by each profile-specific weights.sh wrapper.
set -euo pipefail

HF_CLI_VENV="${HF_CLI_VENV:-${XDG_DATA_HOME:-${HOME}/.local/share}/subconscious/hf-cli}"

log() { printf '[weights] %s\n' "$*"; }
die() { printf '[weights] ERROR: %s\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

python_is_supported() {
  "$1" -c 'import sys; raise SystemExit(0 if sys.version_info >= (3, 9) else 1)' \
    >/dev/null 2>&1
}

select_hf_python() {
  local candidate
  if [[ -n "${HF_CLI_PYTHON:-}" ]]; then
    have "$HF_CLI_PYTHON" || die "HF_CLI_PYTHON is not executable: $HF_CLI_PYTHON"
    python_is_supported "$HF_CLI_PYTHON" ||
      die "HF_CLI_PYTHON must be Python 3.9 or newer: $HF_CLI_PYTHON"
    printf '%s\n' "$HF_CLI_PYTHON"
    return
  fi

  for candidate in python3.13 python3.12 python3.11 python3.10 python3.9 python3; do
    if have "$candidate" && python_is_supported "$candidate"; then
      command -v "$candidate"
      return
    fi
  done
  die "Python 3.9 or newer is required; rerun the profile installer"
}

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
elif [[ -x "$HF_CLI_VENV/bin/hf" ]]; then
  HF_CLI_BIN="$HF_CLI_VENV/bin/hf"
else
  HF_PYTHON="$(select_hf_python)"
  log "installing the Hugging Face CLI with $($HF_PYTHON --version 2>&1) in $HF_CLI_VENV"
  "$HF_PYTHON" -m venv --clear "$HF_CLI_VENV" ||
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
