#!/usr/bin/env bash
# Deploy qwen36-27b (l4 x 4) on Nebius.
set -euo pipefail

exec "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/_deploy.sh" \
  nebius l4 4 qwen36-27b "$@"
