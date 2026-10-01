#!/usr/bin/env bash
# Prepare the GPU host for qwen36-27b-h200-4gpu (h200 x 4) on OCI.
set -euo pipefail

exec "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/profiles/_deploy.sh" \
  oci h200 4 qwen36-27b-h200-4gpu "$@"
