#!/usr/bin/env bash
# Deploy qwen36-27b-h200-8gpu (h200 x 8) on Crusoe.
set -euo pipefail

exec "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/_deploy.sh" \
  crusoe h200 8 qwen36-27b-h200-8gpu "$@"
