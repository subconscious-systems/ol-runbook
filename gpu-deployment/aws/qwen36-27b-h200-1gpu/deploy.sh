#!/usr/bin/env bash
# Prepare the GPU host for qwen36-27b-h200-1gpu (h200 x 1) on AWS.
set -euo pipefail

exec "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/profiles/_deploy.sh" \
  aws h200 1 qwen36-27b-h200-1gpu "$@"
