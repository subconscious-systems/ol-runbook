#!/usr/bin/env bash
# Prepare the GPU host for qwen36-27b-b200-8gpu (b200 x 8) on CoreWeave.
set -euo pipefail

exec "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/profiles/_deploy.sh" \
  coreweave b200 8 qwen36-27b-b200-8gpu "$@"
