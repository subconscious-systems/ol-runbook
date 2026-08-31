#!/usr/bin/env bash
# Download weights for the qwen3-8b-l4-1gpu profile.
set -euo pipefail

PROFILE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "${PROFILE_DIR}/../_weights.sh" "qwen3-8b-l4-1gpu" \
  "Qwen/Qwen3-8B-FP8" "/models/hf/Qwen3-8B-FP8"
