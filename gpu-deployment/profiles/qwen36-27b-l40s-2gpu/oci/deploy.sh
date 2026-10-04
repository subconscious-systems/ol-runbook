#!/usr/bin/env bash
# Deploy qwen36-27b-l40s-2gpu (l40s x 2) on OCI.
set -euo pipefail

exec "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/_deploy.sh" \
  oci l40s 2 qwen36-27b-l40s-2gpu "$@"
