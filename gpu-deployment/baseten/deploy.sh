#!/usr/bin/env bash
# Select a native Baseten Truss config. No SSH, k3s, or host bootstrap.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec python3 "${SCRIPT_DIR}/push_truss.py" "$@"
