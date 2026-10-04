#!/usr/bin/env bash
# Prepare the GPU host for qwen36-27b-l40s-1gpu (l40s x 1) on Nebius.
set -euo pipefail

exec "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/profiles/_deploy.sh" \
  nebius l40s 1 qwen36-27b-l40s-1gpu "$@"
