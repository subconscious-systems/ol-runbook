#!/usr/bin/env bash
# Install the Distr Kubernetes agent through the IAM-protected GKE DNS endpoint.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

usage() {
  cat >&2 <<'EOF'
usage:
  connect-k8s-agent.sh <sandbox|prod> <INFRA_DEPLOY_NAME> \
    'kubectl apply -n <GATEWAY_DEPLOY_NAME> -f "https://.../api/v1/connect?..."'

The cluster name is derived as <INFRA_DEPLOY_NAME>-gke. The namespace parsed
from the Hub command must be the gateway Distr deployment and Helm release name.
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi
if [[ $# -ne 3 ]]; then
  usage
  exit 2
fi

ENVIRONMENT_ARG="$1"
INFRA_DEPLOY_NAME="$2"
HUB_LINE="$3"

bootstrap_assert_dns1123 "${INFRA_DEPLOY_NAME}" "INFRA_DEPLOY_NAME"
CLUSTER_NAME="${INFRA_DEPLOY_NAME}-gke"

if [[ ! "${HUB_LINE}" =~ -n[[:space:]]+([a-z0-9]([-a-z0-9]*[a-z0-9])?) ]]; then
  printf 'ERROR: could not find -n <namespace> in the Hub command\n' >&2
  exit 2
fi
GATEWAY_NAMESPACE="${BASH_REMATCH[1]}"

if [[ ! "${HUB_LINE}" =~ -f[[:space:]]+[\'\"]?(https://[^\'\"[:space:]]+) ]]; then
  printf 'ERROR: could not find -f <connect-url> in the Hub command\n' >&2
  exit 2
fi
CONNECT_URL="${BASH_REMATCH[1]}"

if [[ ! "${CONNECT_URL}" =~ ^https://[^[:space:]]+/api/v1/connect\?[^[:space:]]+$ ]]; then
  printf 'ERROR: expected an HTTPS Distr /api/v1/connect URL\n' >&2
  exit 2
fi

bootstrap_resolve_targets "${ENVIRONMENT_ARG}"
bootstrap_print_target
bootstrap_ensure_host "${SCRIPT_DIR}/host-setup.sh"

printf '[connect-k8s-agent] cluster=%s namespace=%s via DNS endpoint\n' \
  "${CLUSTER_NAME}" "${GATEWAY_NAMESPACE}"

{
  printf 'PROJECT_ID=%q\n' "${PROJECT_ID}"
  printf 'REGION=%q\n' "${REGION}"
  printf 'CLUSTER_NAME=%q\n' "${CLUSTER_NAME}"
  printf 'NAMESPACE=%q\n' "${GATEWAY_NAMESPACE}"
  printf 'CONNECT_URL=%q\n' "${CONNECT_URL}"
  cat <<'REMOTE'
set -euo pipefail

gcloud container clusters get-credentials "${CLUSTER_NAME}" \
  --project="${PROJECT_ID}" \
  --location="${REGION}" \
  --dns-endpoint

SERVER="$(kubectl config view --minify -o jsonpath="{.clusters[0].cluster.server}")"
case "${SERVER}" in
  https://*.gke.goog) ;;
  *)
    echo "ERROR: kubeconfig is not using a GKE DNS endpoint: ${SERVER}" >&2
    exit 1
    ;;
esac

kubectl get namespace "${NAMESPACE}" >/dev/null 2>&1 \
  || kubectl create namespace "${NAMESPACE}"
kubectl apply -n "${NAMESPACE}" -f "${CONNECT_URL}"
kubectl -n "${NAMESPACE}" rollout status deployment/distr-agent --timeout=5m
kubectl -n "${NAMESPACE}" get pods,deploy
REMOTE
} | bootstrap_ssh \
  --command='sudo env HOME=/root KUBECONFIG=/root/.kube/config USE_GKE_GCLOUD_AUTH_PLUGIN=True bash -s'

printf '[connect-k8s-agent] connected; verify the Kubernetes target in Distr Hub\n'
printf '[connect-k8s-agent] queued gateway deployment will reconcile automatically\n'
