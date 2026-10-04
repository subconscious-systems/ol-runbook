#!/usr/bin/env bash
# Deploy qwen36-27b-l4-8gpu (l4 x 8) on Azure.
set -euo pipefail

exec "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/_deploy.sh" \
  azure l4 8 qwen36-27b-l4-8gpu "$@"
