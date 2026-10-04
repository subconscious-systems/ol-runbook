#!/usr/bin/env bash
# Prepare the GPU host for qwen36-27b-h200-8gpu (h200 x 8) on CoreWeave.
set -euo pipefail

exec "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/profiles/_deploy.sh" \
  coreweave h200 8 qwen36-27b-h200-8gpu "$@"
