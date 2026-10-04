#!/usr/bin/env bash
# Deploy glm-5.2-b200-8gpu (b200 x 8) on Azure.
set -euo pipefail

exec "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/_deploy.sh" \
  azure b200 8 glm-5.2-b200-8gpu "$@"
