#!/usr/bin/env bash
# Install all local bootstrap CLIs on macOS or Debian/Ubuntu.
set -euo pipefail

MODE="install"
if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  printf 'usage: %s [--check]\n' "$0"
  exit 0
elif [[ "${1:-}" == "--check" ]]; then
  MODE="check"
elif [[ $# -ne 0 ]]; then
  printf 'usage: %s [--check]\n' "$0" >&2
  exit 2
fi

check_tools() {
  local missing=0
  for tool in gcloud gke-gcloud-auth-plugin terraform jq; do
    if command -v "${tool}" >/dev/null 2>&1; then
      printf '[install-gcloud] found %s at %s\n' "${tool}" "$(command -v "${tool}")"
    else
      printf '[install-gcloud] missing %s\n' "${tool}" >&2
      missing=1
    fi
  done
  if command -v terraform >/dev/null 2>&1 \
    && command -v jq >/dev/null 2>&1; then
    if terraform version -json 2>/dev/null | jq -e '
      .terraform_version
      | split(".")
      | map(capture("^(?<n>[0-9]+)").n | tonumber) as $v
      | ($v[0] > 1
          or ($v[0] == 1 and $v[1] > 11)
          or ($v[0] == 1 and $v[1] == 11 and $v[2] >= 4))
    ' >/dev/null; then
      printf '[install-gcloud] Terraform version satisfies >= 1.11.4\n'
    else
      printf '[install-gcloud] Terraform 1.11.4 or newer is required\n' >&2
      missing=1
    fi
  fi
  return "${missing}"
}

if [[ "${MODE}" == "check" ]]; then
  check_tools
  exit
fi

case "$(uname -s)" in
  Darwin)
    if ! command -v brew >/dev/null 2>&1; then
      printf 'ERROR: Homebrew is required on macOS: https://brew.sh\n' >&2
      exit 1
    fi
    if ! command -v gcloud >/dev/null 2>&1; then
      brew install --cask google-cloud-sdk
      hash -r
    fi
    if ! command -v jq >/dev/null 2>&1; then
      brew install jq
      hash -r
    fi
    if ! command -v terraform >/dev/null 2>&1; then
      brew tap hashicorp/tap
      brew install hashicorp/tap/terraform
      hash -r
    fi
    if ! command -v gke-gcloud-auth-plugin >/dev/null 2>&1; then
      gcloud components install gke-gcloud-auth-plugin --quiet
      SDK_ROOT="$(gcloud info --format='value(installation.sdk_root)')"
      [[ -x "${SDK_ROOT}/bin/gke-gcloud-auth-plugin" ]] || {
        printf 'ERROR: gcloud installed the GKE auth component without its executable\n' >&2
        exit 1
      }
      ln -sf \
        "${SDK_ROOT}/bin/gke-gcloud-auth-plugin" \
        "$(brew --prefix)/bin/gke-gcloud-auth-plugin"
      hash -r
    fi
    ;;
  Linux)
    if [[ ! -r /etc/os-release ]]; then
      printf 'ERROR: cannot identify this Linux distribution\n' >&2
      exit 1
    fi
    # shellcheck source=/dev/null
    source /etc/os-release
    case "${ID:-}" in
      debian|ubuntu)
        if [[ "${EUID}" -eq 0 ]]; then
          SUDO=()
        else
          command -v sudo >/dev/null 2>&1 || {
            printf 'ERROR: sudo is required for system package installation\n' >&2
            exit 1
          }
          SUDO=(sudo)
        fi

        "${SUDO[@]}" apt-get update -y
        "${SUDO[@]}" apt-get install -y ca-certificates curl gnupg jq
        "${SUDO[@]}" install -d -m 0755 /etc/apt/keyrings
        curl --proto '=https' --tlsv1.2 -fsSL \
          https://packages.cloud.google.com/apt/doc/apt-key.gpg \
          | "${SUDO[@]}" gpg --dearmor --yes -o /etc/apt/keyrings/cloud.google.gpg
        printf '%s\n' \
          'deb [signed-by=/etc/apt/keyrings/cloud.google.gpg] https://packages.cloud.google.com/apt cloud-sdk main' \
          | "${SUDO[@]}" tee /etc/apt/sources.list.d/google-cloud-sdk.list >/dev/null
        if ! command -v terraform >/dev/null 2>&1; then
          curl --proto '=https' --tlsv1.2 -fsSL \
            https://apt.releases.hashicorp.com/gpg \
            | "${SUDO[@]}" gpg --dearmor --yes \
              -o /etc/apt/keyrings/hashicorp.gpg
          printf 'deb [signed-by=/etc/apt/keyrings/hashicorp.gpg] https://apt.releases.hashicorp.com %s main\n' \
            "${VERSION_CODENAME}" \
            | "${SUDO[@]}" tee /etc/apt/sources.list.d/hashicorp.list >/dev/null
        fi
        "${SUDO[@]}" apt-get update -y
        "${SUDO[@]}" apt-get install -y \
          google-cloud-cli \
          google-cloud-cli-gke-gcloud-auth-plugin \
          terraform
        ;;
      *)
        printf 'ERROR: automated Linux install supports Debian/Ubuntu; use the official package instructions for %s\n' \
          "${ID:-unknown}" >&2
        printf 'https://cloud.google.com/sdk/docs/install\n' >&2
        exit 1
        ;;
    esac
    ;;
  *)
    printf 'ERROR: unsupported operating system: %s\n' "$(uname -s)" >&2
    exit 1
    ;;
esac

if ! check_tools; then
  printf 'ERROR: install completed but required commands are not on PATH; open a new shell and rerun --check\n' >&2
  exit 1
fi

gcloud version
gke-gcloud-auth-plugin --version
terraform version
jq --version
printf '[install-gcloud] next: %s/setup-gcloud.sh\n' \
  "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
