#!/usr/bin/env bash
# Deploy qwen36-27b-h100-80gb-1gpu (h100-80gb x 1) on OCI.
set -euo pipefail

exec "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/_deploy.sh" \
  oci h100-80gb 1 qwen36-27b-h100-80gb-1gpu "$@"
