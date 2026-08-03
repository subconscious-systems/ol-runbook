#!/usr/bin/env bash
# Connect the Distr Docker agent without placing its one-time URL in a file.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

usage() {
  cat >&2 <<'EOF'
usage: run-agent.sh <sandbox|prod> 'https://app.distr.sh/api/v1/connect?...'

Pass only the HTTPS connect URL copied from Distr Hub. The URL is sent over the
IAP SSH stdin stream and is not written to this repository or the VM filesystem.
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi
if [[ $# -ne 2 ]]; then
  usage
  exit 2
fi

ENVIRONMENT_ARG="$1"
CONNECT_URL="$2"

if [[ ! "${CONNECT_URL}" =~ ^https://[^[:space:]]+/api/v1/connect\?[^[:space:]]+$ ]]; then
  printf 'ERROR: expected an HTTPS Distr /api/v1/connect URL\n' >&2
  exit 2
fi

bootstrap_resolve_targets "${ENVIRONMENT_ARG}"
bootstrap_print_target
bootstrap_ensure_host "${SCRIPT_DIR}/host-setup.sh"

printf '[run-agent] sending the one-time connect URL over IAP stdin\n'
{
  printf 'CONNECT_URL=%q\n' "${CONNECT_URL}"
  cat <<'REMOTE'
set -euo pipefail
case "${CONNECT_URL}" in
  https://*/api/v1/connect\?*) ;;
  *)
    echo "ERROR: invalid connect URL" >&2
    exit 2
    ;;
esac
curl --proto "=https" --tlsv1.2 -fsSL "${CONNECT_URL}" \
  | docker compose -f - up -d
docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Image}}"
REMOTE
} | bootstrap_ssh --command='sudo bash -s'

printf '[run-agent] Docker agent connect completed; verify target health in Distr Hub\n'
