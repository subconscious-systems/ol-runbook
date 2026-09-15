#!/usr/bin/env bash
# Prepare the GPU host for glm-5.2-b200-8gpu (b200 x 8) on Crusoe.
set -euo pipefail

exec "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/profiles/_deploy.sh" \
  crusoe b200 8 glm-5.2-b200-8gpu "$@"
