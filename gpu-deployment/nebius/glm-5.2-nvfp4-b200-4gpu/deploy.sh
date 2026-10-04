#!/usr/bin/env bash
# Prepare the GPU host for glm-5.2-nvfp4-b200-4gpu (b200 x 4) on Nebius.
set -euo pipefail

exec "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/profiles/_deploy.sh" \
  nebius b200 4 glm-5.2-nvfp4-b200-4gpu "$@"
