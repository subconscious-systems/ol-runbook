#!/usr/bin/env bash
# Deploy qwen36-27b-l40s-4gpu (l40s x 4) on Crusoe.
set -euo pipefail

exec "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/_deploy.sh" \
  crusoe l40s 4 qwen36-27b-l40s-4gpu "$@"
