#!/usr/bin/env bash
# Offline contract checks for shell wrappers and the sample GCP environment.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "${TEST_DIR}/.." && pwd)"
BOOTSTRAP_DIR="$(cd "${SCRIPTS_DIR}/.." && pwd)"
GCP_DIR="$(cd "${BOOTSTRAP_DIR}/.." && pwd)"
RUNBOOK_DIR="$(git -C "${GCP_DIR}" rev-parse --show-toplevel)"
SAMPLE_ENV="${GCP_DIR}/sample-gateway-infra.env"

REMOTE_SCRIPT_FILES=(
  "${SCRIPTS_DIR}/connect-k8s-agent.sh"
  "${SCRIPTS_DIR}/connect.sh"
  "${SCRIPTS_DIR}/rotate-app-secret.sh"
  "${SCRIPTS_DIR}/run-agent.sh"
  "${SCRIPTS_DIR}/smoke-checks.sh"
)

for script in "${SCRIPTS_DIR}"/*.sh "${TEST_DIR}"/*.sh; do
  if [[ ! -x "${script}" ]]; then
    printf 'ERROR: script is not executable: %s\n' "${script}" >&2
    exit 1
  fi
  bash -n "${script}"
done

for script in "${REMOTE_SCRIPT_FILES[@]}"; do
  remote_body="$(
    awk '
      /cat <<.REMOTE./ { capture=1; next }
      capture && /^[[:space:]]*REMOTE[[:space:]]*$/ { exit }
      capture { print }
    ' "${script}"
  )"
  if [[ -z "${remote_body}" ]]; then
    printf 'ERROR: no REMOTE shell block found in %s\n' "${script}" >&2
    exit 1
  fi
  bash -n <<<"${remote_body}"
  if command -v shellcheck >/dev/null 2>&1; then
    shellcheck --shell=bash - <<<"${remote_body}"
  fi
done

for script in \
  "${SCRIPTS_DIR}/bootstrap.sh" \
  "${SCRIPTS_DIR}/connect.sh" \
  "${SCRIPTS_DIR}/connect-k8s-agent.sh" \
  "${SCRIPTS_DIR}/install-gcloud.sh" \
  "${SCRIPTS_DIR}/migrate-state.sh" \
  "${SCRIPTS_DIR}/preflight.sh" \
  "${SCRIPTS_DIR}/repair-host.sh" \
  "${SCRIPTS_DIR}/rotate-app-secret.sh" \
  "${SCRIPTS_DIR}/run-agent.sh" \
  "${SCRIPTS_DIR}/setup-gcloud.sh" \
  "${SCRIPTS_DIR}/smoke-checks.sh"; do
  bash "${script}" --help >/dev/null 2>&1
done

required_env_lines=(
  "CLOUD=gcp"
  "GCP_REGION=us-east1"
  "GKE_RELEASE_CHANNEL=REGULAR"
  "GCP_NODE_MACHINE_TYPE=n4a-standard-4"
  "NODE_DESIRED_SIZE=2"
  "NODE_MIN_SIZE=2"
  "NODE_MAX_SIZE=4"
  "CLUSTER_ENDPOINT_PUBLIC_ACCESS=false"
  "CLOUDSQL_TIER=db-custom-2-7680"
  "CLOUDSQL_STORAGE_GB=50"
  "MEMORYSTORE_MEMORY_GB=5"
  "GCP_DELETION_PROTECTION=true"
  "GCP_EXTERNAL_DNS_ENABLED=false"
  "DATADOG_GCP_CLOUD_METRICS_ENABLED=true"
  "DATADOG_DATABASE_MONITORS_ENABLED=false"
  "GATEWAY_AUTO_DEPLOY=false"
  "GATEWAY_CHART_VERSION=latest"
  "DISTR_DRY_RUN=0"
)

for line in "${required_env_lines[@]}"; do
  grep -Fxq "${line}" "${SAMPLE_ENV}" || {
    printf 'ERROR: sample environment is missing: %s\n' "${line}" >&2
    exit 1
  }
done

for secret_ref in DISTR_TOKEN DD_API_KEY DD_APP_KEY GATEWAY_DASHBOARD_BOOTSTRAP_PASSWORD; do
  grep -Fq "{{.Secrets.${secret_ref}}}" "${SAMPLE_ENV}" || {
    printf 'ERROR: GCP sample does not match the AWS Hub secret contract: %s\n' \
      "${secret_ref}" >&2
    exit 1
  }
done

grep -Fq 'billing_account = var.billing_account_id' \
  "${BOOTSTRAP_DIR}/billing.tf"
grep -Fq 'resource "google_project" "environment"' \
  "${BOOTSTRAP_DIR}/projects.tf"
grep -Fq 'resource "google_project_iam_member" "platform_dns"' \
  "${BOOTSTRAP_DIR}/iam.tf"
grep -Fq 'project = var.dns_project_id' \
  "${BOOTSTRAP_DIR}/iam.tf"
grep -Fq 'bootstrap_subnet_cidr must be a canonical RFC1918 /24' \
  "${BOOTSTRAP_DIR}/variables.tf"
grep -Eq '^[[:space:]]*project_id[[:space:]]*=[[:space:]]*var\.project_id$' \
  "${BOOTSTRAP_DIR}/projects.tf"
# shellcheck disable=SC2016 # Match literal shell code in the implementation.
grep -Fq 'terraform -chdir="${TF_DIR}" apply -input=false "${PLAN_FILE}"' \
  "${SCRIPTS_DIR}/bootstrap.sh"
for api in \
  billingbudgets.googleapis.com \
  cloudbilling.googleapis.com \
  cloudresourcemanager.googleapis.com \
  iam.googleapis.com \
  serviceusage.googleapis.com; do
  grep -Fq "${api}" "${SCRIPTS_DIR}/setup-gcloud.sh"
done
grep -Fq '"orgpolicy.googleapis.com"' "${BOOTSTRAP_DIR}/locals.tf"
grep -Fq '"roles/orgpolicy.policyViewer"' "${BOOTSTRAP_DIR}/locals.tf"
grep -Fq 'C0147pk0i' "${GCP_DIR}/datadog-operations.md"
# shellcheck disable=SC2016 # Match literal shell code in the implementation.
grep -Fq 'CLUSTER_NAME="${INFRA_DEPLOY_NAME}-gke"' \
  "${SCRIPTS_DIR}/connect-k8s-agent.sh"
# shellcheck disable=SC2016 # Match literal shell code in the implementation.
grep -Fq 'CLUSTER_NAME="${INFRA_DEPLOY_NAME}-gke"' \
  "${SCRIPTS_DIR}/connect.sh"
grep -Fq 'CLUSTER_NAME=%q' \
  "${SCRIPTS_DIR}/rotate-app-secret.sh"
# AWS-aligned day-0 CLI: URL as the Docker-agent argument and full Hub command
# as the second Kubernetes-agent argument.
grep -Fq 'CONNECT_URL="$1"' "${SCRIPTS_DIR}/run-agent.sh"
grep -Fq 'HUB_LINE="$2"' "${SCRIPTS_DIR}/connect-k8s-agent.sh"
grep -Fq '"${SCRIPT_DIR}/migrate-state.sh" --yes' \
  "${SCRIPTS_DIR}/bootstrap.sh"

legacy_environment_label='sand''box'
if git -C "${RUNBOOK_DIR}" grep -qi "${legacy_environment_label}" \
  -- api-gateway/gcp; then
  printf 'ERROR: legacy environment terminology remains in the production-only GCP runbook\n' >&2
  exit 1
fi

if grep -Eq '(BEGIN (RSA|OPENSSH|PRIVATE) KEY|\"type\"[[:space:]]*:[[:space:]]*\"service_account\")' \
  "${GCP_DIR}"/*.md "${GCP_DIR}"/*.env "${BOOTSTRAP_DIR}"/*.tf; then
  printf 'ERROR: key-like credential material found in GCP runbook\n' >&2
  exit 1
fi

printf '[test] OK: shell blocks, locked sample contract, and credential scan passed\n'
