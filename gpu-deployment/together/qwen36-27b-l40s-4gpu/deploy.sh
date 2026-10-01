#!/usr/bin/env bash
# Prepare the GPU host for qwen36-27b-l40s-4gpu (l40s x 4) on Together AI.
set -euo pipefail

exec "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/profiles/_deploy.sh" \
  together l40s 4 qwen36-27b-l40s-4gpu "$@"
