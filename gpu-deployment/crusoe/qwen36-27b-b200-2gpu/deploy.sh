#!/usr/bin/env bash
# Prepare the GPU host for qwen36-27b-b200-2gpu (b200 x 2) on Crusoe.
set -euo pipefail

exec "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/profiles/_deploy.sh" \
  crusoe b200 2 qwen36-27b-b200-2gpu "$@"
