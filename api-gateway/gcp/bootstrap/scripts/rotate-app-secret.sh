#!/usr/bin/env bash
# Rotate CSRF or credential-encryption material with the GCP-enabled runner image.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

usage() {
  cat >&2 <<'EOF'
usage:
  rotate-app-secret.sh <sandbox|prod> csrf <INFRA_DEPLOY_NAME> <GATEWAY_DEPLOY_NAME>
  rotate-app-secret.sh <sandbox|prod> encryption <INFRA_DEPLOY_NAME> <GATEWAY_DEPLOY_NAME>

Optional environment:
  RUNNER_IMAGE       Exact entitled GCP-enabled infra runner image
  CLEAR_PREVIOUS     0 or 1 (default 1)
  SKIP_GRACE_SLEEP   0 or 1 (default 0)
  RUN_REENCRYPT      0 or 1 (runner default when unset)

The runner release must explicitly advertise the GCP Secret Manager rotation
backend. The script fails closed if that image entrypoint is absent.
EOF
}

rotate_parse_args() {
  if [[ $# -ne 4 ]]; then
    return 2
  fi

  ROTATE_ENVIRONMENT="$1"
  ROTATE_KEY="$(printf '%s' "$2" | tr '[:upper:]' '[:lower:]')"
  INFRA_DEPLOY_NAME="$3"
  GATEWAY_DEPLOY_NAME="$4"

  bootstrap_validate_environment "${ROTATE_ENVIRONMENT}" || return 2
  case "${ROTATE_KEY}" in
    csrf|encryption) ;;
    *) return 2 ;;
  esac
  bootstrap_assert_dns1123 "${INFRA_DEPLOY_NAME}" "INFRA_DEPLOY_NAME" || return 2
  bootstrap_assert_dns1123 "${GATEWAY_DEPLOY_NAME}" "GATEWAY_DEPLOY_NAME" || return 2
}

if [[ "${BASH_SOURCE[0]}" != "${0}" ]]; then
  return 0
fi

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi
if ! rotate_parse_args "$@"; then
  usage
  exit 2
fi

for value in "${CLEAR_PREVIOUS:-1}" "${SKIP_GRACE_SLEEP:-0}" "${RUN_REENCRYPT:-1}"; do
  if [[ "${value}" != "0" && "${value}" != "1" ]]; then
    printf 'ERROR: rotation flags must be 0 or 1\n' >&2
    exit 2
  fi
done

if [[ -n "${RUNNER_IMAGE:-}" && ! "${RUNNER_IMAGE}" =~ ^[A-Za-z0-9._/:@-]+$ ]]; then
  printf 'ERROR: RUNNER_IMAGE contains unsupported characters\n' >&2
  exit 2
fi

bootstrap_resolve_targets "${ROTATE_ENVIRONMENT}"
bootstrap_check_gcloud_auth
bootstrap_wait_vm
bootstrap_print_target

{
  printf 'PROJECT_ID=%q\n' "${PROJECT_ID}"
  printf 'REGION=%q\n' "${REGION}"
  printf 'INFRA_DEPLOY_NAME=%q\n' "${INFRA_DEPLOY_NAME}"
  printf 'GATEWAY_DEPLOY_NAME=%q\n' "${GATEWAY_DEPLOY_NAME}"
  printf 'KEY=%q\n' "${ROTATE_KEY}"
  printf 'RUNNER_IMAGE=%q\n' "${RUNNER_IMAGE:-}"
  printf 'CLEAR_PREVIOUS=%q\n' "${CLEAR_PREVIOUS:-1}"
  printf 'SKIP_GRACE_SLEEP=%q\n' "${SKIP_GRACE_SLEEP:-0}"
  printf 'RUN_REENCRYPT=%q\n' "${RUN_REENCRYPT:-}"
  cat <<'REMOTE'
set -euo pipefail

gcloud container clusters get-credentials "${INFRA_DEPLOY_NAME}" \
  --project="${PROJECT_ID}" \
  --location="${REGION}" \
  --dns-endpoint
kubectl get namespace "${GATEWAY_DEPLOY_NAME}" >/dev/null

if [[ -z "${RUNNER_IMAGE}" ]]; then
  RUNNER_IMAGE="$(docker ps --filter name=runner --format "{{.Image}}" | awk "NF { print; exit }")"
fi
if [[ -z "${RUNNER_IMAGE}" ]]; then
  RUNNER_IMAGE="$(docker ps -a --filter name=runner --format "{{.Image}}" | awk "NF { print; exit }")"
fi
if [[ -z "${RUNNER_IMAGE}" ]]; then
  echo "ERROR: no runner image found; set RUNNER_IMAGE to an entitled GCP-enabled release" >&2
  exit 1
fi

docker run --rm --entrypoint /bin/sh "${RUNNER_IMAGE}" \
  -c "test -x /app/scripts/rotate-gateway-app-secret.sh" || {
  echo "ERROR: runner image lacks the rotation entrypoint" >&2
  exit 1
}

docker run --rm --network host \
  -v /root/.kube:/root/.kube:ro \
  -e HOME=/root \
  -e KUBECONFIG=/root/.kube/config \
  -e USE_GKE_GCLOUD_AUTH_PLUGIN=True \
  -e CLOUD=gcp \
  -e GCP_PROJECT="${PROJECT_ID}" \
  -e GOOGLE_CLOUD_PROJECT="${PROJECT_ID}" \
  -e GCP_REGION="${REGION}" \
  -e DEPLOY_NAME="${INFRA_DEPLOY_NAME}" \
  -e CLUSTER_NAME="${INFRA_DEPLOY_NAME}" \
  -e GATEWAY_NAMESPACE="${GATEWAY_DEPLOY_NAME}" \
  -e KEY="${KEY}" \
  -e CLEAR_PREVIOUS="${CLEAR_PREVIOUS}" \
  -e SKIP_GRACE_SLEEP="${SKIP_GRACE_SLEEP}" \
  -e RUN_REENCRYPT="${RUN_REENCRYPT}" \
  "${RUNNER_IMAGE}" \
  /app/scripts/rotate-gateway-app-secret.sh
REMOTE
} | bootstrap_ssh \
  --command='sudo env HOME=/root KUBECONFIG=/root/.kube/config USE_GKE_GCLOUD_AUTH_PLUGIN=True bash -s'

printf '[rotate-app-secret] %s rotation completed for %s\n' \
  "${ROTATE_KEY}" "${GATEWAY_DEPLOY_NAME}"
