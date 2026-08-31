#!/usr/bin/env bash
# Compatibility entry point. New installs run profiles/install.sh directly.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOCAL_INSTALLER="${SCRIPT_DIR}/profiles/install.sh"

if [[ -x "${LOCAL_INSTALLER}" ]]; then
  exec "${LOCAL_INSTALLER}" "$@"
fi

# Preserve the former one-file curl workflow while keeping the implementation
# beside the profiles for new installs.
INSTALL_URL="https://raw.githubusercontent.com/subconscious-systems/ol-runbook/main/gpu-deployment/profiles/install.sh"
TEMP_INSTALLER="$(mktemp)"
trap 'rm -f "${TEMP_INSTALLER}"' EXIT
curl -fsSL "${INSTALL_URL}" -o "${TEMP_INSTALLER}"
chmod +x "${TEMP_INSTALLER}"
"${TEMP_INSTALLER}" "$@"
