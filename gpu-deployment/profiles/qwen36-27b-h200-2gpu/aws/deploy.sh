#!/usr/bin/env bash
# Deploy qwen36-27b-h200-2gpu (h200 x 2) on AWS.
set -euo pipefail

exec "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/_deploy.sh" \
  aws h200 2 qwen36-27b-h200-2gpu "$@"
