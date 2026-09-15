#!/usr/bin/env bash
# Prepare the GPU host for qwen36-27b-b200-2gpu (b200 x 2) on Together AI.
set -euo pipefail

exec "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/profiles/_deploy.sh" \
  together b200 2 qwen36-27b-b200-2gpu "$@"
