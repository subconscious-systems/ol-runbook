#!/usr/bin/env bash
# Connect the Distr Docker agent without placing its one-time URL in a file.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

usage() {
  cat >&2 <<'EOF'
usage: run-agent.sh

The script securely prompts for the one-time Docker target connect URL copied
from Distr Hub. The URL is sent over the IAP SSH stdin stream and is not placed
in shell history or written to this repository or the VM filesystem.
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi
if [[ $# -ne 0 ]]; then
  usage
  exit 2
fi

if [[ -t 0 ]]; then
  printf 'Paste the Distr Docker target connect URL: ' >&2
  IFS= read -r -s CONNECT_URL
  printf '\n' >&2
else
  IFS= read -r CONNECT_URL
fi

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
