#!/usr/bin/env bash
# Deploy qwen36-27b-b200-4gpu (b200 x 4) on AWS.
set -euo pipefail

exec "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/_deploy.sh" \
  aws b200 4 qwen36-27b-b200-4gpu "$@"
