#!/usr/bin/env bash
# Prepare the GPU host for qwen36-27b-h100-80gb-1gpu (h100-80gb x 1) on AWS.
set -euo pipefail

exec "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/profiles/_deploy.sh" \
  aws h100-80gb 1 qwen36-27b-h100-80gb-1gpu "$@"
