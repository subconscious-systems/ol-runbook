#!/usr/bin/env bash
# Reapply Docker/gcloud/kubectl setup over keyless IAP/OS Login.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  printf 'usage: %s\n' "$0"
  exit 0
fi
if [[ $# -ne 0 ]]; then
  printf 'usage: %s\n' "$0" >&2
  exit 2
fi

bootstrap_resolve_targets
bootstrap_print_target
bootstrap_ensure_host "${SCRIPT_DIR}/host-setup.sh"
printf '[repair-host] host is ready\n'
