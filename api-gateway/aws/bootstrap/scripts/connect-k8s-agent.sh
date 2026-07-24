#!/usr/bin/env bash
# Install the Distr Kubernetes agent into EKS via SSM on the bootstrap EC2.
#
# The K8s agent runs as pods in the gateway namespace. The EKS cluster name is
# the infra DEPLOY_NAME; this host is only a kubectl client.
#
# Paste the full Hub connect command (single-quoted):
#   ./scripts/connect-k8s-agent.sh \
#     acme-api-gateway-infra \
#     'kubectl apply -n api-gateway-acme -f "https://app.distr.sh/api/v1/connect?targetId=…&targetSecret=…"'
#
# Prerequisites: platforms/aws applied (cluster exists); Docker agent host bootstrapped.
# Idempotent. Use Distr Hub "Reconnect" if the targetSecret was exposed or lost.
# See https://distr.sh/docs/agents/kubernetes-agent/
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
  ./scripts/connect-k8s-agent.sh \
    <INFRA_DEPLOY_NAME> \
    'kubectl apply -n <GATEWAY_DISTR_DEPLOYMENT_NAME> -f "https://app.distr.sh/api/v1/connect?…"'

INFRA_DEPLOY_NAME is the Terraform name_prefix / EKS cluster name.
Paste the full Hub Kubernetes-agent connect command (single-quoted); its
namespace must equal GATEWAY_DISTR_DEPLOYMENT_NAME.
EOF
}

if [[ $# -ne 2 ]]; then
  usage
  exit 2
fi

CLUSTER_NAME="$1"
HUB_LINE="$2"

if [[ ! "${CLUSTER_NAME}" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]]; then
  echo "ERROR: INFRA_DEPLOY_NAME must be a lowercase DNS label" >&2
  usage
  exit 2
fi

if [[ ! "${HUB_LINE}" =~ -n[[:space:]]+([a-z0-9]([-a-z0-9]*[a-z0-9])?) ]]; then
  echo "ERROR: could not find -n <namespace> in the Hub command" >&2
  usage
  exit 2
fi
GATEWAY_NAMESPACE="${BASH_REMATCH[1]}"

if [[ ! "${HUB_LINE}" =~ -f[[:space:]]+[\'\"]?(https://[^\'\"[:space:]]+) ]]; then
  echo "ERROR: could not find -f <connect-url> in the Hub command" >&2
  usage
  exit 2
fi
CONNECT_URL="${BASH_REMATCH[1]}"

if [[ "${CONNECT_URL}" != https://*/api/v1/connect* ]]; then
  echo "ERROR: connect URL must look like https://…/api/v1/connect?…" >&2
  exit 2
fi

# Ensure Docker/compose/kubectl on the host, then run kubectl remotely.
bootstrap_ensure_host "${SCRIPT_DIR}/host-setup.sh"

# Escape URL for remote shell (no eval of Hub line).
URL_Q="$(printf '%q' "${CONNECT_URL}")"
CLUSTER_Q="$(printf '%q' "${CLUSTER_NAME}")"
NS_Q="$(printf '%q' "${GATEWAY_NAMESPACE}")"
REGION_Q="$(printf '%q' "${REGION}")"

# SSM RunShellScript leaves HOME empty; awscli still writes to /root/.kube/config
# (passwd home), but kubectl resolves config via $HOME and falls back to
# localhost:8080 when HOME is unset.
REMOTE="set -euo pipefail
export HOME=/root
export KUBECONFIG=/root/.kube/config
export AWS_REGION=${REGION_Q}
CLUSTER=${CLUSTER_Q}
NS=${NS_Q}
URL=${URL_Q}

echo \"[connect-k8s-agent] update-kubeconfig cluster=\${CLUSTER} region=\${AWS_REGION}\"
aws eks update-kubeconfig --name \"\${CLUSTER}\" --region \"\${AWS_REGION}\"

if kubectl get namespace \"\${NS}\" >/dev/null 2>&1; then
  echo \"[connect-k8s-agent] namespace \${NS} already exists\"
else
  echo \"[connect-k8s-agent] creating namespace \${NS}\"
  kubectl create namespace \"\${NS}\"
fi

echo \"[connect-k8s-agent] applying Distr K8s agent manifests\"
kubectl apply -n \"\${NS}\" -f \"\${URL}\"

echo \"[connect-k8s-agent] waiting for distr-agent rollout\"
kubectl -n \"\${NS}\" rollout status deployment/distr-agent --timeout=3m

echo \"[connect-k8s-agent] pods:\"
kubectl -n \"\${NS}\" get pods,deploy
echo \"[connect-k8s-agent] done — agent should appear healthy in Distr Hub\"
"

echo "[connect-k8s-agent] cluster=${CLUSTER_NAME} namespace=${GATEWAY_NAMESPACE}"
echo "[connect-k8s-agent] deploying Distr K8s agent into EKS…"
bootstrap_ssm_run "${REMOTE}" 600 "connect-k8s-agent"

echo "[connect-k8s-agent] OK — Distr Kubernetes agent should be connected"
echo "Next: set GATEWAY_AUTO_DEPLOY=true and re-run the infra Docker deployment (or deploy the gateway app in Hub)."
