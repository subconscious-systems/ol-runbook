#!/usr/bin/env bash
# Deploy qwen36-27b-l40s-2gpu (l40s x 2) on Fireworks AI.
set -euo pipefail

exec "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/_deploy.sh" \
  fireworks l40s 2 qwen36-27b-l40s-2gpu "$@"
