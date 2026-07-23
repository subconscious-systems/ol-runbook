#!/usr/bin/env bash
# Run the Distr Docker-agent connect command on the bootstrap EC2 via SSM.
#
# Preferred (paste the Hub connect URL only — no shell quoting fights):
#   ./scripts/run-agent.sh 'https://app.distr.sh/api/v1/connect?targetId=…&targetSecret=…'
#
# Or the full Hub command (use DOUBLE quotes on the outside):
#   ./scripts/run-agent.sh "curl -fsSL 'https://…/connect?…' | docker compose -f - up -d"
#
# Requires: aws CLI, jq, terraform outputs from a prior ./scripts/bootstrap.sh apply.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TF_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"
cd "${TF_DIR}"

bootstrap_need aws
bootstrap_need jq
bootstrap_need terraform

usage() {
  cat >&2 <<'EOF'
usage:
  ./scripts/run-agent.sh 'https://app.distr.sh/api/v1/connect?targetId=…&targetSecret=…'
  ./scripts/run-agent.sh "curl -fsSL 'https://…' | docker compose -f - up -d"

Tip: pass only the https:// connect URL from Distr Hub (single-quoted).
EOF
}

if [[ $# -lt 1 ]]; then
  usage
  exit 2
fi

ARG="$*"
if [[ "${ARG}" == https://* || "${ARG}" == http://* ]]; then
  # Build the install command ourselves so ? and & never hit the local shell.
  CONNECT_CMD="curl -fsSL $(printf '%q' "${ARG}") | docker compose -f - up -d"
elif [[ "${ARG}" == curl* || "${ARG}" == *"docker compose"* ]]; then
  CONNECT_CMD="${ARG}"
else
  echo "ERROR: pass a Distr connect URL (https://…) or a full curl|compose command" >&2
  usage
  exit 2
fi

# Idempotent: same instance, push/run host-setup if Docker/compose missing or stale.
bootstrap_ensure_host "${SCRIPT_DIR}/host-setup.sh"

B64="$(printf '%s' "${CONNECT_CMD}" | base64 | tr -d '\n')"
REMOTE="set -euo pipefail
echo '[run-agent] decoding connect command'
CMD=\$(printf '%s' '${B64}' | base64 -d)
echo '[run-agent] executing Distr connect…'
bash -lc \"\$CMD\"
echo '[run-agent] connect finished'
docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Image}}' || true
"

echo "[run-agent] sending Distr connect command via SSM Run Command…"
bootstrap_ssm_run "${REMOTE}" 600 "run-agent"

echo "[run-agent] OK — Distr Docker agent should be connected"
