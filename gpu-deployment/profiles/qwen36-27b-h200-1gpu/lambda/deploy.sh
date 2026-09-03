#!/usr/bin/env bash
# Deploy qwen36-27b-h200-1gpu (h200 x 1) on Lambda.
set -euo pipefail

exec "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/_deploy.sh" \
  lambda h200 1 qwen36-27b-h200-1gpu "$@"
