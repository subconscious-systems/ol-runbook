#!/usr/bin/env bash
# Prepare the GPU host for qwen3-8b-l4-1gpu (l4 x 4) on Nebius.
set -euo pipefail

exec "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/profiles/_deploy.sh" \
  nebius l4 4 qwen3-8b-l4-1gpu "$@"
