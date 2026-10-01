#!/usr/bin/env bash
# Prepare the GPU host for qwen36-27b-b200-8gpu (b200 x 8) on Crusoe.
set -euo pipefail

exec "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/profiles/_deploy.sh" \
  crusoe b200 8 qwen36-27b-b200-8gpu "$@"
