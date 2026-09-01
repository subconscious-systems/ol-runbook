#!/usr/bin/env bash
# Download weights for the glm-5.2-nvfp4-b200-4gpu profile.
set -euo pipefail

PROFILE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "${PROFILE_DIR}/../_weights.sh" "glm-5.2-nvfp4-b200-4gpu" \
  "nvidia/GLM-5.2-NVFP4" "/mnt/model-test/glm-5.2-nvfp4" \
  "SubconsciousDev/glm-5.2-fp8-dflash-v2" "/mnt/model-test/glm-5.2-fp8-dflash-v2"
