#!/usr/bin/env bash
# Prepare the GPU host for qwen36-27b-h200-1gpu (h200 x 1) on Together AI.
set -euo pipefail

exec "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/profiles/_deploy.sh" \
  together h200 1 qwen36-27b-h200-1gpu "$@"
