#!/usr/bin/env bash
# Deploy qwen36-27b-l40s-8gpu (l40s x 8) on AWS.
set -euo pipefail

exec "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/_deploy.sh" \
  aws l40s 8 qwen36-27b-l40s-8gpu "$@"
