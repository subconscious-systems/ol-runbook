#!/usr/bin/env bash
# Prepare the GPU host for qwen36-27b-a100-80gb-1gpu (a100-80gb x 1) on OCI.
set -euo pipefail

exec "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/profiles/_deploy.sh" \
  oci a100-80gb 1 qwen36-27b-a100-80gb-1gpu "$@"
