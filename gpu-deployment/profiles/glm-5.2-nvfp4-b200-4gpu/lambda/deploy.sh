#!/usr/bin/env bash
# Deploy glm-5.2-nvfp4-b200-4gpu (b200 x 4) on Lambda.
set -euo pipefail

exec "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/_deploy.sh" \
  lambda b200 4 glm-5.2-nvfp4-b200-4gpu "$@"
