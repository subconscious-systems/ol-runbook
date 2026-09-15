#!/usr/bin/env bash
# Deploy qwen36-27b-l4-4gpu (l4 x 4) on Fireworks AI.
set -euo pipefail

exec "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/_deploy.sh" \
  fireworks l4 4 qwen36-27b-l4-4gpu "$@"
