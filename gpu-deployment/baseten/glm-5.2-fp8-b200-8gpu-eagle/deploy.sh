#!/usr/bin/env bash
# Push only the glm-5.2-fp8-b200-8gpu-eagle Truss configuration.
set -euo pipefail
exec "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/deploy.sh" \
  glm-5.2-fp8-b200-8gpu-eagle "$@"
