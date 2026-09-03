#!/usr/bin/env bash
# Deploy qwen36-27b-b200-1gpu (b200 x 1) on Crusoe.
set -euo pipefail

exec "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/_deploy.sh" \
  crusoe b200 1 qwen36-27b-b200-1gpu "$@"
