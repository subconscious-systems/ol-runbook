#!/usr/bin/env bash
# Destroy the AWS platform Terraform stack via SSM on the bootstrap EC2.
# Uses the same lib.sh connection path as connect.sh / rotate-app-secret.sh,
# then runs teardown-platform.sh from the entitled api-gateway-infra runner image.
#
# Usage:
#   ./scripts/teardown-platform.sh --yes <INFRA_DEPLOY_NAME> <GATEWAY_DEPLOY_NAME>
#
# Example:
#   ./scripts/teardown-platform.sh --yes awsgateway-api-gateway-infra awsgateway-api-gateway
#
# Optional env:
#   RUNNER_IMAGE   Pin or override the infra runner image (default: discover
#                  from a running *runner* container on the host)
#   AWS_REGION     Override region (else terraform output aws_region)
#   INSTANCE_ID    Override bootstrap instance (else terraform output)
#
# Requires: aws CLI, jq, terraform outputs from ./scripts/bootstrap.sh.
# Docs: ../../teardown.md
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TF_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

usage() {
  cat >&2 <<'EOF'
usage:
  ./scripts/teardown-platform.sh --yes <INFRA_DEPLOY_NAME> <GATEWAY_DEPLOY_NAME>

INFRA_DEPLOY_NAME    Distr Docker / Terraform name prefix (EKS cluster name)
GATEWAY_DEPLOY_NAME  Distr Helm deploy name / Kubernetes namespace

Undeploy the gateway Helm app in Hub first. Take an RDS snapshot in AWS if you
need the data. This script does not snapshot. It fails if the namespace still
has Deployments.

Uses bootstrap SSM (same as connect.sh). Copies Hub env from the idle infra
runner container and runs teardown-platform.sh in the entitled runner image
(--entrypoint so the apply entrypoint does not run).

Optional: RUNNER_IMAGE=registry.distr.sh/subconscious/api-gateway-infra/runner:<tag>
EOF
}

# Parse + validate CLI. Sets INFRA_DEPLOY_NAME, GATEWAY_DEPLOY_NAME.
# Return 0 on success, 2 on usage/validation error. Does not touch AWS/terraform.
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

  if [[ $# -lt 2 ]]; then
    usage
    return 2
  fi

  INFRA_DEPLOY_NAME="${1}"
  GATEWAY_DEPLOY_NAME="${2}"

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

teardown_platform_ssm_timeout() {
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

  cd "${TF_DIR}"
  bootstrap_need aws
  bootstrap_need jq
  bootstrap_need terraform

  bootstrap_resolve_targets
  bootstrap_wait_ssm

  local INFRA_Q GATEWAY_Q REGION_Q RUNNER_IMAGE_Q
  local KUBE_REMOTE DESTROY_REMOTE SSM_TIMEOUT

  INFRA_Q="$(printf '%q' "${INFRA_DEPLOY_NAME}")"
  GATEWAY_Q="$(printf '%q' "${GATEWAY_DEPLOY_NAME}")"
  REGION_Q="$(printf '%q' "${REGION}")"
  RUNNER_IMAGE_Q=""
  if [[ -n "${RUNNER_IMAGE:-}" ]]; then
    RUNNER_IMAGE_Q="$(printf '%q' "${RUNNER_IMAGE}")"
  fi

  KUBE_REMOTE="set -euo pipefail
export HOME=/root
export KUBECONFIG=/root/.kube/config
export AWS_REGION=${REGION_Q}
CLUSTER=${INFRA_Q}

if aws eks describe-cluster --name \"\${CLUSTER}\" --region \"\${AWS_REGION}\" >/dev/null 2>&1; then
  echo \"[teardown] update-kubeconfig cluster=\${CLUSTER} region=\${AWS_REGION}\"
  aws eks update-kubeconfig --name \"\${CLUSTER}\" --region \"\${AWS_REGION}\"
  echo \"[teardown] kubeconfig ready\"
else
  echo \"[teardown] EKS cluster \${CLUSTER} not found; skipping kubeconfig\"
fi
"

  echo "[teardown] refreshing kubeconfig for cluster ${INFRA_DEPLOY_NAME}…"
  bootstrap_ssm_run "${KUBE_REMOTE}" 120 "teardown-kubeconfig"

  SSM_TIMEOUT="$(teardown_platform_ssm_timeout)"

  DESTROY_REMOTE="set -euo pipefail
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

RUNNER_CID=\"\$(docker ps --filter name=runner --format '{{.ID}}' | head -n1 || true)\"
if [[ -z \"\${RUNNER_CID}\" ]]; then
  RUNNER_CID=\"\$(docker ps -a --filter name=runner --format '{{.ID}}' | head -n1 || true)\"
fi
if [[ -z \"\${RUNNER_CID}\" ]]; then
  echo 'ERROR: no runner container on this host; keep the infra Docker app idle in Hub so Hub env can be copied' >&2
  exit 1
fi

ENV_FILE=\$(mktemp)
trap 'rm -f \"\${ENV_FILE}\"' EXIT
docker inspect \"\${RUNNER_CID}\" --format '{{range .Config.Env}}{{println .}}{{end}}' >\"\${ENV_FILE}\"
echo \"[teardown] using RUNNER_IMAGE=\${RUNNER_IMAGE} cid=\${RUNNER_CID}\"

docker run --rm --network host \\
  --entrypoint /app/scripts/teardown-platform.sh \\
  --env-file \"\${ENV_FILE}\" \\
  -e HOME=/root \\
  -e KUBECONFIG=/root/.kube/config \\
  -e AWS_REGION -e AWS_DEFAULT_REGION \\
  -e TEARDOWN_CONFIRM=${INFRA_Q} \\
  -e GATEWAY_NAMESPACE=${GATEWAY_Q} \\
  -v /root/.kube:/root/.kube \\
  \"\${RUNNER_IMAGE}\"
"

  echo "[teardown] destroying platform ${INFRA_DEPLOY_NAME} on ${INSTANCE_ID} (timeout ${SSM_TIMEOUT}s)…"
  bootstrap_ssm_run "${DESTROY_REMOTE}" "${SSM_TIMEOUT}" "teardown-platform"

  echo "[teardown] OK - platform destroy finished for ${INFRA_DEPLOY_NAME}"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  teardown_platform_main "$@"
fi
