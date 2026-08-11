#!/usr/bin/env bash
# Break-glass IAP/OS Login shell, optionally refreshing root's GKE kubeconfig.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

usage() {
  cat >&2 <<'EOF'
usage:
  connect.sh <sandbox|prod> [INFRA_DEPLOY_NAME]

Uses IAP and OS Login; the VM has no public IP and no static SSH key. When a
deployment name is supplied, root's kubeconfig is refreshed for the derived
<INFRA_DEPLOY_NAME>-gke cluster with --dns-endpoint before the interactive
shell opens.
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi
if [[ $# -lt 1 || $# -gt 2 ]]; then
  usage
  exit 2
fi

ENVIRONMENT_ARG="$1"
INFRA_DEPLOY_NAME="${2:-}"
CLUSTER_NAME=""
if [[ -n "${INFRA_DEPLOY_NAME}" ]]; then
  bootstrap_assert_dns1123 "${INFRA_DEPLOY_NAME}" "INFRA_DEPLOY_NAME"
  CLUSTER_NAME="${INFRA_DEPLOY_NAME}-gke"
fi

bootstrap_resolve_targets "${ENVIRONMENT_ARG}"
bootstrap_check_gcloud_auth
bootstrap_wait_vm
bootstrap_print_target

if [[ -n "${CLUSTER_NAME}" ]]; then
  {
    printf 'PROJECT_ID=%q\n' "${PROJECT_ID}"
    printf 'REGION=%q\n' "${REGION}"
    printf 'CLUSTER_NAME=%q\n' "${CLUSTER_NAME}"
    cat <<'REMOTE'
set -euo pipefail
gcloud container clusters get-credentials "${CLUSTER_NAME}" \
  --project="${PROJECT_ID}" \
  --location="${REGION}" \
  --dns-endpoint
kubectl cluster-info
REMOTE
  } | bootstrap_ssh \
    --command='sudo env HOME=/root KUBECONFIG=/root/.kube/config USE_GKE_GCLOUD_AUTH_PLUGIN=True bash -s'
fi

cat >&2 <<'EOF'
[connect] opening an IAP/OS Login shell.
For root-owned Docker and kubeconfig:
  sudo -i
  export HOME=/root KUBECONFIG=/root/.kube/config
  export USE_GKE_GCLOUD_AUTH_PLUGIN=True
EOF

exec gcloud compute ssh "${VM_NAME}" \
  --project="${PROJECT_ID}" \
  --zone="${ZONE}" \
  --tunnel-through-iap
