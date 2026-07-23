#!/usr/bin/env bash
# Break-glass: interactive SSM shell on the Docker-agent EC2 for cluster debug.
#
# Day-0 EKS API is CIDR-locked to this host. Prefer kubectl from here over
# laptop kubeconfig. Distinct from connect-k8s-agent.sh (agent install).
#
# Usage:
#   ./scripts/connect.sh <DEPLOY_NAME>   # refresh kubeconfig, then shell
#   ./scripts/connect.sh                 # shell only
#   DEPLOY_NAME=api-gateway-acme ./scripts/connect.sh
#
# Requires: aws CLI, Session Manager plugin, terraform outputs from bootstrap.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TF_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"
cd "${TF_DIR}"

bootstrap_need aws
bootstrap_need terraform

usage() {
  cat >&2 <<'EOF'
usage:
  ./scripts/connect.sh <DEPLOY_NAME>   # refresh kubeconfig on host, then SSM shell
  ./scripts/connect.sh                 # SSM shell only (skip kubeconfig refresh)
  DEPLOY_NAME=api-gateway-acme ./scripts/connect.sh

Break-glass debug on the Docker-agent EC2 (EKS API is CIDR-locked to this host).
Requires the Session Manager plugin: https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

DEPLOY_NAME="${1:-${DEPLOY_NAME:-}}"

if ! command -v session-manager-plugin >/dev/null 2>&1; then
  echo "ERROR: session-manager-plugin is required for interactive SSM sessions." >&2
  echo "Install: https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html" >&2
  exit 1
fi

bootstrap_resolve_targets
bootstrap_wait_ssm

if [[ -n "${DEPLOY_NAME}" ]]; then
  if [[ ! "${DEPLOY_NAME}" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]]; then
    echo "ERROR: DEPLOY_NAME must be a DNS-1123 label (got: ${DEPLOY_NAME})" >&2
    usage
    exit 2
  fi

  CLUSTER_Q="$(printf '%q' "${DEPLOY_NAME}")"
  REGION_Q="$(printf '%q' "${REGION}")"
  REMOTE="set -euo pipefail
export HOME=/root
export KUBECONFIG=/root/.kube/config
export AWS_REGION=${REGION_Q}
CLUSTER=${CLUSTER_Q}

echo \"[connect] update-kubeconfig cluster=\${CLUSTER} region=\${AWS_REGION}\"
aws eks update-kubeconfig --name \"\${CLUSTER}\" --region \"\${AWS_REGION}\"
echo \"[connect] kubeconfig ready\"
"

  echo "[connect] refreshing kubeconfig for cluster ${DEPLOY_NAME}…"
  bootstrap_ssm_run "${REMOTE}" 120 "connect-kubeconfig"
fi

NS_HINT="<GATEWAY_DISTR_DEPLOYMENT_NAME>"
cat >&2 <<EOF
[connect] SSM session → ${INSTANCE_ID} (${REGION})
On the box:

  # kubeconfig (HOME is often unset under SSM)
  export HOME=/root KUBECONFIG=/root/.kube/config

  # infra Docker agent / runner
  docker ps -a --filter name=runner
  docker logs --tail 200 distr-*-runner-1

  # gateway namespace (separate from the infra DEPLOY_NAME / cluster)
  kubectl -n ${NS_HINT} get pods,deploy,svc
  kubectl -n ${NS_HINT} logs deploy/<name> --tail=200
  kubectl -n ${NS_HINT} describe pod/<name>

  # identity break-glass (see ol-runbook api-gateway/aws/troubleshooting.md)
  kubectl -n ${NS_HINT} exec -it deploy/<adapter> -- ops-cli identity bootstrap …

EOF

echo "[connect] starting interactive session (exit to leave)…"
exec aws ssm start-session --target "${INSTANCE_ID}" --region "${REGION}"
