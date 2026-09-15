#!/usr/bin/env bash
# Show deployment guidance for qwen36-27b-h100-80gb-1gpu (h100-80gb x 1) on Fireworks AI.
set -euo pipefail

exec "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/profiles/_deploy.sh" \
  fireworks h100-80gb 1 qwen36-27b-h100-80gb-1gpu "$@"
