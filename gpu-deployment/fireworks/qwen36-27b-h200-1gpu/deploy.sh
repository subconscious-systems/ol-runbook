#!/usr/bin/env bash
# Show deployment guidance for qwen36-27b-h200-1gpu (h200 x 1) on Fireworks AI.
set -euo pipefail

exec "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/profiles/_deploy.sh" \
  fireworks h200 1 qwen36-27b-h200-1gpu "$@"
