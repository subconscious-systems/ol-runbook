#!/usr/bin/env bash
# Deploy qwen36-27b-l40s-1gpu (l40s x 1) on AWS.
set -euo pipefail

exec "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/_deploy.sh" \
  aws l40s 1 qwen36-27b-l40s-1gpu "$@"
