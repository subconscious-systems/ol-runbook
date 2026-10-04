#!/usr/bin/env bash
# Prepare the GPU host for qwen36-27b-b200-4gpu (b200 x 4) on Together AI.
set -euo pipefail

exec "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/profiles/_deploy.sh" \
  together b200 4 qwen36-27b-b200-4gpu "$@"
