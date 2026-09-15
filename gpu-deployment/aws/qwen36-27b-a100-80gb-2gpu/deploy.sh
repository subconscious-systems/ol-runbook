#!/usr/bin/env bash
# Prepare the GPU host for qwen36-27b-a100-80gb-2gpu (a100-80gb x 2) on AWS.
set -euo pipefail

exec "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/profiles/_deploy.sh" \
  aws a100-80gb 2 qwen36-27b-a100-80gb-2gpu "$@"
