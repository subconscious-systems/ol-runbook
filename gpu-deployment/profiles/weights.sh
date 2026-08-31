#!/usr/bin/env bash
# Download all Hugging Face repositories declared by one GPU profile before
# applying that profile through Distr.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HF_CLI_VENV="${HF_CLI_VENV:-${XDG_DATA_HOME:-${HOME}/.local/share}/subconscious/hf-cli}"

log() { printf '[weights] %s\n' "$*"; }
die() { printf '[weights] ERROR: %s\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

usage() {
  cat <<'EOF'
Usage: ./weights.sh <profile.yaml>

Prompts for a Hugging Face token and a download root, then downloads every
repository declared in worker.modelDownload. The token is neither echoed nor
placed on the command line.

Examples:
  ./weights.sh glm-5.2-nvfp4-b200-4gpu.yaml
  ./weights.sh glm-5.2-b200-4gpu.yaml
EOF
}

[[ $# -eq 1 ]] || { usage >&2; exit 2; }
case "$1" in
  -h|--help) usage; exit 0 ;;
esac

PROFILE="$1"
if [[ "$PROFILE" != /* ]]; then
  if [[ -f "$PROFILE" ]]; then
    PROFILE="$(cd "$(dirname "$PROFILE")" && pwd)/$(basename "$PROFILE")"
  else
    PROFILE="${SCRIPT_DIR}/${PROFILE}"
  fi
fi
[[ -f "$PROFILE" ]] || die "profile not found: $PROFILE"

DOWNLOAD_ROWS=()
while IFS= read -r row; do
  DOWNLOAD_ROWS+=("$row")
done < <(
  awk '
    /^[[:space:]]*(-[[:space:]]*)?hfRepo:[[:space:]]*/ {
      repo=$0
      sub(/^[^:]*:[[:space:]]*/, "", repo)
      gsub(/^['"'"']|['"'"']$/, "", repo)
      next
    }
    /^[[:space:]]*targetPath:[[:space:]]*/ && repo != "" {
      target=$0
      sub(/^[^:]*:[[:space:]]*/, "", target)
      gsub(/^['"'"']|['"'"']$/, "", target)
      print repo "\t" target
      repo=""
    }
  ' "$PROFILE"
)

[[ ${#DOWNLOAD_ROWS[@]} -gt 0 ]] ||
  die "profile has no hfRepo/targetPath download metadata: $PROFILE"

DEFAULT_ROOT=""
for row in "${DOWNLOAD_ROWS[@]}"; do
  IFS=$'\t' read -r repo target <<<"$row"
  [[ -n "$repo" && "$target" == /* ]] || die "invalid download metadata in $PROFILE"
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

log "profile: $(basename "$PROFILE")"
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
  have python3 || die "python3 is required; run ./install.sh first"
  log "installing the Hugging Face CLI in $HF_CLI_VENV"
  python3 -m venv "$HF_CLI_VENV" ||
    die "could not create a Python venv; run ./install.sh first"
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
