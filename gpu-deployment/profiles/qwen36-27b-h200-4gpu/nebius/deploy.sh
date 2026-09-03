#!/usr/bin/env bash
# Deploy qwen36-27b-h200-4gpu (h200 x 4) on Nebius.
set -euo pipefail

exec "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/_deploy.sh" \
  nebius h200 4 qwen36-27b-h200-4gpu "$@"
