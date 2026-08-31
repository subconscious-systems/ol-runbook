#!/usr/bin/env bash
# Connect the Distr Docker agent without placing its one-time URL in a file.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

usage() {
  cat >&2 <<'EOF'
usage:
  ./scripts/run-agent.sh
  ./scripts/run-agent.sh --stdin

The no-argument form securely prompts for the Docker target connect URL copied
from Distr Hub. --stdin is for the guided installer. Both keep the credential
out of shell history and process arguments. The legacy URL argument is accepted
for compatibility but is not recommended.
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

CONNECT_URL=""
case "$#" in
  0)
    [[ -t 0 ]] || {
      printf 'ERROR: interactive input requires a terminal; use --stdin\n' >&2
      exit 2
    }
    printf 'Paste the Docker target connect URL (input hidden): '
    read -r -s CONNECT_URL
    printf '\n'
    ;;
  1)
    if [[ "$1" == "--stdin" ]]; then
      IFS= read -r CONNECT_URL
    else
      CONNECT_URL="$1"
      printf 'WARNING: URL arguments may appear in shell history/process lists; use the secure prompt\n' >&2
    fi
    ;;
  *)
    usage
    exit 2
    ;;
esac

if [[ ! "${CONNECT_URL}" =~ ^https://app\.distr\.sh/api/v1/connect\?[^[:space:]]+$ ]]; then
  printf 'ERROR: expected an https://app.distr.sh/api/v1/connect URL\n' >&2
  exit 2
fi
if [[ "${CONNECT_URL}" == *\"* || "${CONNECT_URL}" == *\'* \
  || "${CONNECT_URL}" == *\\* ]]; then
  printf 'ERROR: connect URL contains an unsafe quote or backslash\n' >&2
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
curl --proto "=https" --tlsv1.2 -fsSL \
  --config <(printf 'url = "%s"\n' "${CONNECT_URL}") \
  | docker compose -f - up -d
docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Image}}"
REMOTE
} | bootstrap_ssh --command='sudo bash -s'

printf '[run-agent] Docker agent connect completed; verify target health in Distr Hub\n'
