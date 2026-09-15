#!/usr/bin/env bash
# Download weights for the qwen3-8b-l4-1gpu profile.
set -euo pipefail

PROFILE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOWNLOADER="${PROFILE_DIR}/../../profiles/_weights.sh"
# The SSH helper stages the shared downloader beside the remote profile.
[[ -x "$DOWNLOADER" ]] || DOWNLOADER="${PROFILE_DIR}/../_weights.sh"
exec "$DOWNLOADER" "qwen3-8b-l4-1gpu" \
  "Qwen/Qwen3-8B-FP8" "/models/hf/Qwen3-8B-FP8"
