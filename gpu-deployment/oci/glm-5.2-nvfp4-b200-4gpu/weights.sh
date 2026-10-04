#!/usr/bin/env bash
# Download weights for the glm-5.2-nvfp4-b200-4gpu profile.
set -euo pipefail

PROFILE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOWNLOADER="${PROFILE_DIR}/../../profiles/_weights.sh"
# The SSH helper stages the shared downloader beside the remote profile.
[[ -x "$DOWNLOADER" ]] || DOWNLOADER="${PROFILE_DIR}/../_weights.sh"
exec "$DOWNLOADER" "glm-5.2-nvfp4-b200-4gpu" \
  "nvidia/GLM-5.2-NVFP4" "/mnt/model-test/glm-5.2-nvfp4" \
  "SubconsciousDev/glm-5.2-fp8-dflash-v2" "/mnt/model-test/glm-5.2-fp8-dflash-v2"
