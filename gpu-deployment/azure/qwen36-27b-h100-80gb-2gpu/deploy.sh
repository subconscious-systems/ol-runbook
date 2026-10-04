#!/usr/bin/env bash
# Prepare the GPU host for qwen36-27b-h100-80gb-2gpu (h100-80gb x 2) on Azure.
set -euo pipefail

exec "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/profiles/_deploy.sh" \
  azure h100-80gb 2 qwen36-27b-h100-80gb-2gpu "$@"
