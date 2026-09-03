#!/usr/bin/env bash
# Deploy qwen36-27b-h100-80gb-4gpu (h100-80gb x 4) on Baseten.
set -euo pipefail

exec "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/_deploy.sh" \
  baseten h100-80gb 4 qwen36-27b-h100-80gb-4gpu "$@"
