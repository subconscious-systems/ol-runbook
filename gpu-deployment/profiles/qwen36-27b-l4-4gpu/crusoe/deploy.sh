#!/usr/bin/env bash
# Deploy qwen36-27b-l4-4gpu (l4 x 4) on Crusoe.
set -euo pipefail

exec "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/_deploy.sh" \
  crusoe l4 4 qwen36-27b-l4-4gpu "$@"
