#!/usr/bin/env bash
# Deploy qwen36-27b-b200-8gpu (b200 x 8) on Azure.
set -euo pipefail

exec "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/_deploy.sh" \
  azure b200 8 qwen36-27b-b200-8gpu "$@"
