#!/usr/bin/env bash
# Download weights for the glm-5.2-b200-8gpu profile.
set -euo pipefail

PROFILE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "${PROFILE_DIR}/../_weights.sh" "glm-5.2-b200-8gpu" \
  "zai-org/GLM-5.2-FP8" "/models/hf/GLM-5.2-FP8" \
  "SubconsciousDev/glm-5.2-fp8-dflash-v2" "/models/hf/glm-5.2-fp8-dflash-v2"
