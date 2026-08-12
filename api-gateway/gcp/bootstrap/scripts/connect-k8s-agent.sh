#!/usr/bin/env bash
# Install the Distr Kubernetes agent through the IAM-protected GKE DNS endpoint.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

usage() {
  cat >&2 <<'EOF'
usage:
  connect-k8s-agent.sh <INFRA_DEPLOY_NAME>

The script securely prompts for the `kubectl apply` command copied from Distr
Hub. The cluster name is derived as <INFRA_DEPLOY_NAME>-gke. The namespace in
the Hub command must be the gateway Distr deployment and Helm release name.
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

INFRA_DEPLOY_NAME="$1"

if [[ -t 0 ]]; then
  printf 'Paste the Distr Kubernetes target connect command: ' >&2
  IFS= read -r -s HUB_LINE
  printf '\n' >&2
else
  IFS= read -r HUB_LINE
fi

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

if [[ ! "${CONNECT_URL}" =~ ^https://app\.distr\.sh/api/v1/connect\?[^[:space:]]+$ ]]; then
  printf 'ERROR: expected an https://app.distr.sh/api/v1/connect URL\n' >&2
  exit 2
fi

bootstrap_resolve_targets
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
printf '[connect-k8s-agent] return to the guided installer or approved recovery workflow\n'
