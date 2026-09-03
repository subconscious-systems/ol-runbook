#!/usr/bin/env bash
# Deploy qwen36-27b-a100-80gb-8gpu (a100-80gb x 8) on CoreWeave.
set -euo pipefail

exec "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/_deploy.sh" \
  coreweave a100-80gb 8 qwen36-27b-a100-80gb-8gpu "$@"
