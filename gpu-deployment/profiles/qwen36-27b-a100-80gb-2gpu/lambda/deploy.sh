#!/usr/bin/env bash
# Deploy qwen36-27b-a100-80gb-2gpu (a100-80gb x 2) on Lambda.
set -euo pipefail

exec "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/_deploy.sh" \
  lambda a100-80gb 2 qwen36-27b-a100-80gb-2gpu "$@"
