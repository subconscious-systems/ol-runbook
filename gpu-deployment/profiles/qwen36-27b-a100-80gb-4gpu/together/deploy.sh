#!/usr/bin/env bash
# Deploy qwen36-27b-a100-80gb-4gpu (a100-80gb x 4) on Together AI.
set -euo pipefail

exec "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/_deploy.sh" \
  together a100-80gb 4 qwen36-27b-a100-80gb-4gpu "$@"
