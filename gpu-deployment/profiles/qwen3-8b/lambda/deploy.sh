#!/usr/bin/env bash
# Deploy qwen3-8b (l4 x 4) on Lambda.
set -euo pipefail

exec "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/_deploy.sh" \
  lambda l4 4 qwen3-8b "$@"
