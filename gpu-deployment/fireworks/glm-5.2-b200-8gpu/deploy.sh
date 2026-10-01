#!/usr/bin/env bash
# Show deployment guidance for glm-5.2-b200-8gpu (b200 x 8) on Fireworks AI.
set -euo pipefail

exec "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/profiles/_deploy.sh" \
  fireworks b200 8 glm-5.2-b200-8gpu "$@"
