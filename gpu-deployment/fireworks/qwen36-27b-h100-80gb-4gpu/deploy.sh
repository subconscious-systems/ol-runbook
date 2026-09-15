#!/usr/bin/env bash
# Show deployment guidance for qwen36-27b-h100-80gb-4gpu (h100-80gb x 4) on Fireworks AI.
set -euo pipefail

exec "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/profiles/_deploy.sh" \
  fireworks h100-80gb 4 qwen36-27b-h100-80gb-4gpu "$@"
