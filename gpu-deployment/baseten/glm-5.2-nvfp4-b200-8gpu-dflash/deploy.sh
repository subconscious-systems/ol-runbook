#!/usr/bin/env bash
# Push only the glm-5.2-nvfp4-b200-8gpu-dflash Truss configuration.
set -euo pipefail
exec "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/deploy.sh" \
  glm-5.2-nvfp4-b200-8gpu-dflash "$@"
