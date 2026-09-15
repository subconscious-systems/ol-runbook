#!/usr/bin/env bash
# Show deployment guidance for qwen3-8b-l4-1gpu (l4 x 4) on Fireworks AI.
set -euo pipefail

exec "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/profiles/_deploy.sh" \
  fireworks l4 4 qwen3-8b-l4-1gpu "$@"
