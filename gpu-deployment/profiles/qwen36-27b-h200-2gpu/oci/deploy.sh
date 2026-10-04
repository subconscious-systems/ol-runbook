#!/usr/bin/env bash
# Deploy qwen36-27b-h200-2gpu (h200 x 2) on OCI.
set -euo pipefail

exec "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/_deploy.sh" \
  oci h200 2 qwen36-27b-h200-2gpu "$@"
