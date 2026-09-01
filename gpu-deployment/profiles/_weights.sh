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

python_has_venv() {
  "$1" -c 'import ensurepip, venv' >/dev/null 2>&1
}

run_as_root() {
  if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
    "$@"
  elif have sudo; then
    sudo "$@"
  else
    die "sudo is required to install host prerequisites or configure SELinux"
  fi
}

selinux_is_enabled() {
  have getenforce && [[ "$(getenforce)" != "Disabled" ]]
}

ensure_selinux_tools() {
  selinux_is_enabled || return
  have semanage && have restorecon && return

  [[ -r /etc/os-release ]] ||
    die "cannot install SELinux tools automatically without /etc/os-release"
  # shellcheck disable=SC1091
  source /etc/os-release
  case " ${ID:-} ${ID_LIKE:-} " in
    *" debian "* | *" ubuntu "*)
      have apt-get || die "apt-get is required to install SELinux tools"
      log "installing SELinux policy tools with apt"
      run_as_root apt-get update
      run_as_root apt-get install -y policycoreutils policycoreutils-python-utils
      ;;
    *" rhel "* | *" fedora "* | *" centos "*)
      have dnf || die "dnf is required to install SELinux tools"
      log "installing SELinux policy tools with dnf"
      run_as_root dnf install -y policycoreutils policycoreutils-python-utils
      ;;
    *)
      die "SELinux is enabled but semanage or restorecon is missing"
      ;;
  esac

  have semanage || die "SELinux setup did not provide semanage"
  have restorecon || die "SELinux setup did not provide restorecon"
}

selinux_escape_path() {
  local input="$1" escaped="" char index
  for ((index = 0; index < ${#input}; index++)); do
    char="${input:index:1}"
    case "$char" in
      \\ | '.' | '^' | '$' | '*' | '+' | '?' | '(' | ')' | '[' | ']' | '{' | '}' | '|')
        escaped+="\\${char}"
        ;;
      *) escaped+="$char" ;;
    esac
  done
  printf '%s' "$escaped"
}

configure_download_selinux() {
  local download_root="$1" pattern
  selinux_is_enabled || return
  ensure_selinux_tools

  pattern="$(selinux_escape_path "$download_root")(/.*)?"
  log "allowing containers to read $download_root under SELinux"
  if ! run_as_root semanage fcontext -a -t container_file_t "$pattern"; then
    run_as_root semanage fcontext -m -t container_file_t "$pattern"
  fi
  run_as_root restorecon -RF "$download_root"
}

find_hf_python() {
  local candidate
  HF_PYTHON=""
  if [[ -n "${HF_CLI_PYTHON:-}" ]]; then
    have "$HF_CLI_PYTHON" || die "HF_CLI_PYTHON is not executable: $HF_CLI_PYTHON"
    python_is_supported "$HF_CLI_PYTHON" ||
      die "HF_CLI_PYTHON must be Python 3.9 or newer: $HF_CLI_PYTHON"
    HF_PYTHON="$(command -v "$HF_CLI_PYTHON")"
    return
  fi

  for candidate in python3.13 python3.12 python3.11 python3.10 python3.9 python3; do
    if have "$candidate" && python_is_supported "$candidate"; then
      HF_PYTHON="$(command -v "$candidate")"
      return
    fi
  done
  return 1
}

install_hf_python() {
  [[ -r /etc/os-release ]] ||
    die "cannot install Python automatically without /etc/os-release"
  # shellcheck disable=SC1091
  source /etc/os-release
  case " ${ID:-} ${ID_LIKE:-} " in
    *" debian "* | *" ubuntu "*)
      have apt-get || die "apt-get is required to install Python on ${PRETTY_NAME:-this host}"
      log "installing Python and venv packages with apt"
      run_as_root apt-get update
      run_as_root apt-get install -y python3 python3-venv
      ;;
    *" rhel "* | *" fedora "* | *" centos "*)
      have dnf || die "dnf is required to install Python on ${PRETTY_NAME:-this host}"
      log "installing Python 3.11 and pip packages with dnf"
      run_as_root dnf install -y python3.11 python3.11-pip
      ;;
    *)
      die "automatic Python installation supports Debian/Ubuntu and Rocky/RHEL-family hosts"
      ;;
  esac
}

ensure_hf_python() {
  if ! find_hf_python || ! python_has_venv "$HF_PYTHON"; then
    install_hf_python
    find_hf_python ||
      die "Python 3.9 or newer was not available after package installation; set HF_CLI_PYTHON"
  fi
  python_has_venv "$HF_PYTHON" ||
    die "Python venv support is missing for $HF_PYTHON"
  log "verified $($HF_PYTHON --version 2>&1) with venv support"
}

hf_cli_works() {
  [[ -x "$1" ]] && "$1" --version >/dev/null 2>&1
}

ensure_hf_cli() {
  local system_hf=""
  if have hf; then
    system_hf="$(command -v hf)"
  fi

  if [[ -n "$system_hf" ]] && hf_cli_works "$system_hf"; then
    HF_CLI_BIN="$system_hf"
  elif [[ -x "$HF_CLI_VENV/bin/python" ]] &&
    python_is_supported "$HF_CLI_VENV/bin/python" &&
    python_has_venv "$HF_CLI_VENV/bin/python" &&
    hf_cli_works "$HF_CLI_VENV/bin/hf"; then
    HF_CLI_BIN="$HF_CLI_VENV/bin/hf"
    log "verified $("$HF_CLI_VENV/bin/python" --version 2>&1) with venv support"
  else
    ensure_hf_python
    log "installing the Hugging Face CLI in $HF_CLI_VENV"
    "$HF_PYTHON" -m venv --clear "$HF_CLI_VENV" ||
      die "could not create the Python venv at $HF_CLI_VENV"
    "$HF_CLI_VENV/bin/pip" install --upgrade huggingface_hub
    HF_CLI_BIN="$HF_CLI_VENV/bin/hf"
    hf_cli_works "$HF_CLI_BIN" ||
      die "Hugging Face CLI installation did not create a working $HF_CLI_BIN"
  fi
  log "verified Hugging Face CLI at $HF_CLI_BIN"
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
# Fail or repair host prerequisites before asking the operator for a token.
ensure_hf_cli
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
[[ -n "$DOWNLOAD_ROOT" && "$DOWNLOAD_ROOT" != "/" ]] ||
  die "download root must not be /"

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
configure_download_selinux "$DOWNLOAD_ROOT"

export HF_TOKEN="$HF_TOKEN_INPUT"
for row in "${DOWNLOAD_ROWS[@]}"; do
  IFS=$'\t' read -r repo target <<<"$row"
  destination="$DOWNLOAD_ROOT/$(basename "$target")"
  log "downloading $repo to $destination"
  "$HF_CLI_BIN" download "$repo" --local-dir "$destination"
done

# Re-apply the persistent file-context rule so resumed downloads and any files
# created with a different label are readable through an unprivileged hostPath.
if selinux_is_enabled; then
  run_as_root restorecon -RF "$DOWNLOAD_ROOT"
fi

unset HF_TOKEN_INPUT HF_TOKEN
trap - EXIT
log "all profile weights are ready under $DOWNLOAD_ROOT"
