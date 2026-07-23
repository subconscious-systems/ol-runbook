#!/usr/bin/env bash
# Ensure Docker/compose on the bootstrap EC2 (idempotent; safe to re-run).
# Does not replace the instance — pushes and runs scripts/host-setup.sh via SSM.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TF_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"
cd "${TF_DIR}"

bootstrap_need aws
bootstrap_need jq
bootstrap_need terraform

bootstrap_ensure_host "${SCRIPT_DIR}/host-setup.sh"
