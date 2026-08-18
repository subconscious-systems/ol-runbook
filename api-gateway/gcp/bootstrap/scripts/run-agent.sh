#!/usr/bin/env bash
# Connect the Distr Docker agent without placing its one-time URL in a file.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

usage() {
  cat >&2 <<'EOF'
usage:
  ./scripts/run-agent.sh 'https://app.distr.sh/api/v1/connect?targetId=…&targetSecret=…'

Pass the Docker target connect URL copied from Distr Hub. It is sent over the
IAP SSH stream and is not written to this repository or the VM filesystem.
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi
if [[ $# -ne 1 ]]; then
  usage
  exit 2
fi
CONNECT_URL="$1"

if [[ ! "${CONNECT_URL}" =~ ^https://app\.distr\.sh/api/v1/connect\?[^[:space:]]+$ ]]; then
  printf 'ERROR: expected an https://app.distr.sh/api/v1/connect URL\n' >&2
  exit 2
fi

bootstrap_resolve_targets
bootstrap_print_target
bootstrap_ensure_host "${SCRIPT_DIR}/host-setup.sh"

printf '[run-agent] sending the one-time connect URL over IAP stdin\n'
{
  printf 'CONNECT_URL=%q\n' "${CONNECT_URL}"
  cat <<'REMOTE'
set -euo pipefail
case "${CONNECT_URL}" in
  https://app.distr.sh/api/v1/connect\?*) ;;
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
