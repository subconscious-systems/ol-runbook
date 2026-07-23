#!/usr/bin/env bash
# Rotate gateway app secrets (csrf / encryption) via SSM on the bootstrap EC2.
# Uses the same lib.sh connection path as connect.sh, then runs the rotate
# script from the entitled api-gateway-infra runner image on the host.
#
# Usage:
#   ./scripts/rotate-app-secret.sh csrf <INFRA_DEPLOY_NAME> <GATEWAY_DEPLOY_NAME>
#   ./scripts/rotate-app-secret.sh encryption <INFRA_DEPLOY_NAME> <GATEWAY_DEPLOY_NAME>
#
# Example:
#   ./scripts/rotate-app-secret.sh csrf awsgateway-api-gateway-infra awsgateway-api-gateway
#
# Optional env:
#   RUNNER_IMAGE   Pin or override the infra runner image (default: discover
#                  from a running *runner* container on the host)
#   AWS_REGION     Override region (else terraform output aws_region)
#   INSTANCE_ID    Override bootstrap instance (else terraform output)
#   CLEAR_PREVIOUS / SKIP_GRACE_SLEEP / RUN_REENCRYPT  forwarded to the image script
#
# Requires: aws CLI, jq, terraform outputs from ./scripts/bootstrap.sh.
# Docs: ../../secret-rotation.md
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TF_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

usage() {
  cat >&2 <<'EOF'
usage:
  ./scripts/rotate-app-secret.sh csrf <INFRA_DEPLOY_NAME> <GATEWAY_DEPLOY_NAME>
  ./scripts/rotate-app-secret.sh encryption <INFRA_DEPLOY_NAME> <GATEWAY_DEPLOY_NAME>

INFRA_DEPLOY_NAME  Distr Docker / Terraform name prefix (EKS cluster name, SM path)
GATEWAY_DEPLOY_NAME  Distr Helm deploy name / Kubernetes namespace

Uses bootstrap SSM (same as connect.sh). Runs rotate-gateway-app-secret.sh inside
the entitled api-gateway-infra runner image on the Docker-agent host.

Optional: RUNNER_IMAGE=registry.distr.sh/subconscious/api-gateway-infra/runner:<tag>
EOF
}

# Parse + validate CLI. Sets KEY_ALIAS, INFRA_DEPLOY_NAME, GATEWAY_DEPLOY_NAME.
# Return 0 on success, 2 on usage/validation error. Does not touch AWS/terraform.
rotate_app_secret_parse_args() {
  KEY_ALIAS=""
  INFRA_DEPLOY_NAME=""
  GATEWAY_DEPLOY_NAME=""

  if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    usage
    return 0
  fi

  if [[ $# -lt 3 ]]; then
    usage
    return 2
  fi

  KEY_ALIAS="$(printf '%s' "${1}" | tr '[:upper:]' '[:lower:]')"
  INFRA_DEPLOY_NAME="${2}"
  GATEWAY_DEPLOY_NAME="${3}"

  case "${KEY_ALIAS}" in
    csrf|encryption) ;;
    *)
      echo "ERROR: KEY must be csrf or encryption (got: ${1})" >&2
      usage
      return 2
      ;;
  esac

  local dns1123='^[a-z0-9]([-a-z0-9]*[a-z0-9])?$'
  if [[ ! "${INFRA_DEPLOY_NAME}" =~ ${dns1123} ]]; then
    echo "ERROR: INFRA_DEPLOY_NAME must be a DNS-1123 label (got: ${INFRA_DEPLOY_NAME})" >&2
    return 2
  fi
  if [[ ! "${GATEWAY_DEPLOY_NAME}" =~ ${dns1123} ]]; then
    echo "ERROR: GATEWAY_DEPLOY_NAME must be a DNS-1123 label (got: ${GATEWAY_DEPLOY_NAME})" >&2
    return 2
  fi
  return 0
}

# SSM timeout seconds for the rotate remote command.
rotate_app_secret_ssm_timeout() {
  local key_alias="$1"
  if [[ "${key_alias}" == "encryption" ]]; then
    printf '1800\n'
  else
    printf '2400\n'
  fi
}

rotate_app_secret_main() {
  if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    usage
    exit 0
  fi

  if ! rotate_app_secret_parse_args "$@"; then
    exit 2
  fi

  cd "${TF_DIR}"
  bootstrap_need aws
  bootstrap_need jq
  bootstrap_need terraform

  bootstrap_resolve_targets
  bootstrap_wait_ssm

  local INFRA_Q GATEWAY_Q REGION_Q KEY_Q
  local CLEAR_PREVIOUS_Q SKIP_GRACE_Q RUN_REENCRYPT_Q RUNNER_IMAGE_Q
  local KUBE_REMOTE ROTATE_REMOTE SSM_TIMEOUT

  INFRA_Q="$(printf '%q' "${INFRA_DEPLOY_NAME}")"
  GATEWAY_Q="$(printf '%q' "${GATEWAY_DEPLOY_NAME}")"
  REGION_Q="$(printf '%q' "${REGION}")"
  KEY_Q="$(printf '%q' "${KEY_ALIAS}")"

  CLEAR_PREVIOUS_Q="$(printf '%q' "${CLEAR_PREVIOUS:-1}")"
  SKIP_GRACE_Q="$(printf '%q' "${SKIP_GRACE_SLEEP:-0}")"
  RUN_REENCRYPT_Q="$(printf '%q' "${RUN_REENCRYPT:-}")"
  RUNNER_IMAGE_Q=""
  if [[ -n "${RUNNER_IMAGE:-}" ]]; then
    RUNNER_IMAGE_Q="$(printf '%q' "${RUNNER_IMAGE}")"
  fi

  KUBE_REMOTE="set -euo pipefail
export HOME=/root
export KUBECONFIG=/root/.kube/config
export AWS_REGION=${REGION_Q}
CLUSTER=${INFRA_Q}

echo \"[rotate] update-kubeconfig cluster=\${CLUSTER} region=\${AWS_REGION}\"
aws eks update-kubeconfig --name \"\${CLUSTER}\" --region \"\${AWS_REGION}\"
echo \"[rotate] checking gateway namespace ${GATEWAY_DEPLOY_NAME}\"
kubectl get namespace ${GATEWAY_Q}
echo \"[rotate] kubeconfig ready\"
"

  echo "[rotate] refreshing kubeconfig for cluster ${INFRA_DEPLOY_NAME}…"
  bootstrap_ssm_run "${KUBE_REMOTE}" 120 "rotate-kubeconfig"

  SSM_TIMEOUT="$(rotate_app_secret_ssm_timeout "${KEY_ALIAS}")"

  ROTATE_REMOTE="set -euo pipefail
export HOME=/root
export KUBECONFIG=/root/.kube/config
export AWS_REGION=${REGION_Q}
export AWS_DEFAULT_REGION=${REGION_Q}

RUNNER_IMAGE=${RUNNER_IMAGE_Q}
if [[ -z \"\${RUNNER_IMAGE}\" ]]; then
  RUNNER_IMAGE=\"\$(docker ps --filter name=runner --format '{{.Image}}' | head -n1 || true)\"
fi
if [[ -z \"\${RUNNER_IMAGE}\" ]]; then
  RUNNER_IMAGE=\"\$(docker ps -a --filter name=runner --format '{{.Image}}' | head -n1 || true)\"
fi
if [[ -z \"\${RUNNER_IMAGE}\" ]]; then
  echo 'ERROR: could not discover runner image; set RUNNER_IMAGE=registry.distr.sh/subconscious/api-gateway-infra/runner:<tag>' >&2
  exit 1
fi
echo \"[rotate] using RUNNER_IMAGE=\${RUNNER_IMAGE}\"

export CLOUD=aws
export DEPLOY_NAME=${INFRA_Q}
export GATEWAY_NAMESPACE=${GATEWAY_Q}
export CLUSTER_NAME=${INFRA_Q}
export KEY=${KEY_Q}
export CLEAR_PREVIOUS=${CLEAR_PREVIOUS_Q}
export SKIP_GRACE_SLEEP=${SKIP_GRACE_Q}
if [[ -n ${RUN_REENCRYPT_Q} ]]; then
  export RUN_REENCRYPT=${RUN_REENCRYPT_Q}
fi

docker run --rm --network host \\
  -v /root/.kube:/root/.kube:ro \\
  -e HOME=/root \\
  -e KUBECONFIG=/root/.kube/config \\
  -e AWS_REGION -e AWS_DEFAULT_REGION \\
  -e CLOUD -e DEPLOY_NAME -e GATEWAY_NAMESPACE -e CLUSTER_NAME -e KEY \\
  -e CLEAR_PREVIOUS -e SKIP_GRACE_SLEEP -e RUN_REENCRYPT \\
  \"\${RUNNER_IMAGE}\" \\
  /app/scripts/rotate-gateway-app-secret.sh
"

  echo "[rotate] running ${KEY_ALIAS} rotation on ${INSTANCE_ID} (timeout ${SSM_TIMEOUT}s)…"
  bootstrap_ssm_run "${ROTATE_REMOTE}" "${SSM_TIMEOUT}" "rotate-app-secret"

  echo "[rotate] OK - ${KEY_ALIAS} rotation finished for ${GATEWAY_DEPLOY_NAME}"
}

# When sourced by tests, skip main.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  rotate_app_secret_main "$@"
fi
