#!/usr/bin/env bash
# Deploy qwen36-27b-b200-1gpu (b200 x 1) on GCP.
set -euo pipefail

exec "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/_deploy.sh" \
  gcp b200 1 qwen36-27b-b200-1gpu "$@"
