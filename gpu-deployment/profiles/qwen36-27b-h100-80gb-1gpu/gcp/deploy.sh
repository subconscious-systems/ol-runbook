#!/usr/bin/env bash
# Deploy qwen36-27b-h100-80gb-1gpu (h100-80gb x 1) on GCP.
set -euo pipefail

exec "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/_deploy.sh" \
  gcp h100-80gb 1 qwen36-27b-h100-80gb-1gpu "$@"
