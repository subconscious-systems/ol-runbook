#!/usr/bin/env bash
# Download weights for the qwen36-27b-h100-80gb-1gpu profile.
set -euo pipefail

PROFILE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "${PROFILE_DIR}/../_weights.sh" "qwen36-27b-h100-80gb-1gpu" \
  "Qwen/Qwen3.6-27B-FP8" "/models/hf/Qwen3.6-27B-FP8"
