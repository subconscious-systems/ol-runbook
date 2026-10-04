#!/usr/bin/env bash
# Prepare the GPU host for qwen36-27b-l40s-2gpu (l40s x 2) on Together AI.
set -euo pipefail

exec "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/profiles/_deploy.sh" \
  together l40s 2 qwen36-27b-l40s-2gpu "$@"
