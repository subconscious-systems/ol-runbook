#!/usr/bin/env bash
# Show deployment guidance for qwen36-27b-l4-2gpu (l4 x 2) on Fireworks AI.
set -euo pipefail

exec "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/profiles/_deploy.sh" \
  fireworks l4 2 qwen36-27b-l4-2gpu "$@"
