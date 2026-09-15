#!/usr/bin/env bash
# Prepare the GPU host for qwen36-27b-l4-2gpu (l4 x 2) on AWS.
set -euo pipefail

exec "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/profiles/_deploy.sh" \
  aws l4 2 qwen36-27b-l4-2gpu "$@"
