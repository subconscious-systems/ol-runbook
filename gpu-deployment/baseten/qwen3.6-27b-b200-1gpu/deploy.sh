#!/usr/bin/env bash
# Push only the qwen3.6-27b-b200-1gpu Truss configuration.
set -euo pipefail
exec "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/deploy.sh" \
  qwen3.6-27b-b200-1gpu "$@"
