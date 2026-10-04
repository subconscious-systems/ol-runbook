#!/usr/bin/env bash
# Prepare the GPU host for qwen36-27b-b200-1gpu (b200 x 1) on CoreWeave.
set -euo pipefail

exec "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/profiles/_deploy.sh" \
  coreweave b200 1 qwen36-27b-b200-1gpu "$@"
