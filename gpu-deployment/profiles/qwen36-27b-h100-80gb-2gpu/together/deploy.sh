#!/usr/bin/env bash
# Deploy qwen36-27b-h100-80gb-2gpu (h100-80gb x 2) on Together AI.
set -euo pipefail

exec "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/_deploy.sh" \
  together h100-80gb 2 qwen36-27b-h100-80gb-2gpu "$@"
