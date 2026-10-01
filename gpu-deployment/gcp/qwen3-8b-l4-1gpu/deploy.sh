#!/usr/bin/env bash
# Prepare the GPU host for qwen3-8b-l4-1gpu (l4 x 1) on GCP.
set -euo pipefail

exec "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/profiles/_deploy.sh" \
  gcp l4 1 qwen3-8b-l4-1gpu "$@"
