#!/usr/bin/env bash
# Destroy the GCP platform Terraform stack via IAP on the bootstrap GCE VM.
# Uses the same lib.sh connection path as connect.sh / rotate-app-secret.sh,
# then runs teardown-platform.sh from the entitled api-gateway-infra runner image.
#
# Usage:
#   ./scripts/teardown-platform.sh --yes <INFRA_DEPLOY_NAME> <GATEWAY_DEPLOY_NAME>
#
# Example:
#   ./scripts/teardown-platform.sh --yes example-api-gateway-infra example-api-gateway
#
# Optional env:
#   RUNNER_IMAGE   Pin or override the infra runner image (default: discover
#                  from a running *runner* container on the host)
#   GCP_PROJECT    Override project (else terraform output)
#   GCP_REGION     Override region (else terraform output)
#   BOOTSTRAP_VM_NAME  Override bootstrap VM (else terraform output)
#
# Requires: gcloud CLI, jq, terraform outputs from ./scripts/bootstrap.sh.
# Docs: ../../teardown.md
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

usage() {
  cat >&2 <<'EOF'
usage:
  ./scripts/teardown-platform.sh --yes <INFRA_DEPLOY_NAME> <GATEWAY_DEPLOY_NAME>

INFRA_DEPLOY_NAME    Distr Docker / Terraform name prefix (GKE cluster is <name>-gke)
GATEWAY_DEPLOY_NAME  Distr Helm deploy name / Kubernetes namespace

Undeploy the gateway Helm app in Hub first, then remove distr-agent. Take a
Cloud SQL backup in GCP if you need the data. This script does not snapshot.
It fails if the namespace still has gateway, adapter, or router Deployments.
distr-agent is ignored.

Uses bootstrap IAP SSH (same as rotate-app-secret.sh). Copies Hub env from the
idle infra runner container and runs teardown-platform.sh in the entitled
runner image (--entrypoint so the apply entrypoint does not run). The script
clears live deletion protection; keep Hub GCP_DELETION_PROTECTION=true.

Optional: RUNNER_IMAGE=registry.distr.sh/subconscious/api-gateway-infra/runner:<tag>
EOF
}

# Parse + validate CLI. Sets INFRA_DEPLOY_NAME and GATEWAY_DEPLOY_NAME.
# Return 0 on success, 2 on usage/validation error. Does not touch GCP/terraform.
teardown_platform_parse_args() {
  INFRA_DEPLOY_NAME=""
  GATEWAY_DEPLOY_NAME=""

  if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    usage
    return 0
  fi

  if [[ "${1:-}" != "--yes" ]]; then
    echo "ERROR: refusing to destroy without --yes" >&2
    usage
    return 2
  fi
  shift

  if [[ $# -ne 2 ]]; then
    usage
    return 2
  fi

  INFRA_DEPLOY_NAME="${1}"
  GATEWAY_DEPLOY_NAME="${2}"

  bootstrap_assert_dns1123 "${INFRA_DEPLOY_NAME}" "INFRA_DEPLOY_NAME" || return 2
  bootstrap_assert_dns1123 "${GATEWAY_DEPLOY_NAME}" "GATEWAY_DEPLOY_NAME" || return 2
  return 0
}

teardown_platform_iap_timeout() {
  printf '7200\n'
}

teardown_platform_main() {
  if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    usage
    exit 0
  fi

  if ! teardown_platform_parse_args "$@"; then
    exit 2
  fi

  if [[ -n "${RUNNER_IMAGE:-}" && ! "${RUNNER_IMAGE}" =~ ^[A-Za-z0-9._/:@-]+$ ]]; then
    printf 'ERROR: RUNNER_IMAGE contains unsupported characters\n' >&2
    exit 2
  fi

  bootstrap_resolve_targets
  bootstrap_check_gcloud_auth
  bootstrap_wait_vm
  bootstrap_print_target

  local timeout_seconds
  timeout_seconds="$(teardown_platform_iap_timeout)"

  {
    printf 'PROJECT_ID=%q\n' "${PROJECT_ID}"
    printf 'REGION=%q\n' "${REGION}"
    printf 'INFRA_DEPLOY_NAME=%q\n' "${INFRA_DEPLOY_NAME}"
    printf 'GATEWAY_DEPLOY_NAME=%q\n' "${GATEWAY_DEPLOY_NAME}"
    printf 'RUNNER_IMAGE=%q\n' "${RUNNER_IMAGE:-}"
    printf 'TIMEOUT_SECONDS=%q\n' "${timeout_seconds}"
    cat <<'REMOTE'
set -euo pipefail

CLUSTER_NAME="${INFRA_DEPLOY_NAME}-gke"
export HOME=/root
export KUBECONFIG=/root/.kube/config
export USE_GKE_GCLOUD_AUTH_PLUGIN=True

if gcloud container clusters describe "${CLUSTER_NAME}" \
  --project="${PROJECT_ID}" \
  --location="${REGION}" >/dev/null 2>&1; then
  echo "[teardown] get-credentials cluster=${CLUSTER_NAME} region=${REGION}"
  gcloud container clusters get-credentials "${CLUSTER_NAME}" \
    --project="${PROJECT_ID}" \
    --location="${REGION}" \
    --dns-endpoint
  echo "[teardown] kubeconfig ready"
else
  echo "[teardown] GKE cluster ${CLUSTER_NAME} not found; skipping kubeconfig"
fi

if [[ -z "${RUNNER_IMAGE}" ]]; then
  RUNNER_IMAGE="$(docker ps --filter name=runner --format '{{.Image}}' | awk 'NF { print; exit }')"
fi
if [[ -z "${RUNNER_IMAGE}" ]]; then
  RUNNER_IMAGE="$(docker ps -a --filter name=runner --format '{{.Image}}' | awk 'NF { print; exit }')"
fi
if [[ -z "${RUNNER_IMAGE}" ]]; then
  echo "ERROR: could not discover runner image; set RUNNER_IMAGE=registry.distr.sh/subconscious/api-gateway-infra/runner:<tag>" >&2
  exit 1
fi

RUNNER_CID="$(docker ps --filter name=runner --format '{{.ID}}' | awk 'NF { print; exit }')"
if [[ -z "${RUNNER_CID}" ]]; then
  RUNNER_CID="$(docker ps -a --filter name=runner --format '{{.ID}}' | awk 'NF { print; exit }')"
fi
if [[ -z "${RUNNER_CID}" ]]; then
  echo "ERROR: no runner container on this host; keep the infra Docker app idle in Hub so Hub env can be copied" >&2
  exit 1
fi

ENV_FILE="$(mktemp)"
trap 'rm -f "${ENV_FILE}"' EXIT
docker inspect "${RUNNER_CID}" --format '{{range .Config.Env}}{{println .}}{{end}}' >"${ENV_FILE}"
echo "[teardown] using RUNNER_IMAGE=${RUNNER_IMAGE} cid=${RUNNER_CID}"

docker run --rm --network host \
  --entrypoint /app/scripts/teardown-platform.sh \
  --env-file "${ENV_FILE}" \
  -e HOME=/root \
  -e KUBECONFIG=/root/.kube/config \
  -e USE_GKE_GCLOUD_AUTH_PLUGIN=True \
  -e CLOUD=gcp \
  -e GCP_PROJECT="${PROJECT_ID}" \
  -e GOOGLE_CLOUD_PROJECT="${PROJECT_ID}" \
  -e GCP_REGION="${REGION}" \
  -e TEARDOWN_CONFIRM="${INFRA_DEPLOY_NAME}" \
  -e GATEWAY_NAMESPACE="${GATEWAY_DEPLOY_NAME}" \
  -v /root/.kube:/root/.kube \
  "${RUNNER_IMAGE}"
REMOTE
  } | bootstrap_ssh \
    --command="sudo env HOME=/root KUBECONFIG=/root/.kube/config USE_GKE_GCLOUD_AUTH_PLUGIN=True timeout ${timeout_seconds} bash -s"

  printf '[teardown] OK - platform destroy finished for %s\n' "${INFRA_DEPLOY_NAME}"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  teardown_platform_main "$@"
fi
