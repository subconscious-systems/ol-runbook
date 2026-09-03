#!/usr/bin/env bash
# Deploy qwen36-27b-a100-80gb-1gpu (a100-80gb x 1) on Azure.
set -euo pipefail

exec "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/_deploy.sh" \
  azure a100-80gb 1 qwen36-27b-a100-80gb-1gpu "$@"
