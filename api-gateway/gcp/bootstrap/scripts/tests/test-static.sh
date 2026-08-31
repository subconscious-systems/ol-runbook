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
  "${SCRIPTS_DIR}/teardown-platform.sh"
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
  "${SCRIPTS_DIR}/install.sh" \
  "${SCRIPTS_DIR}/install-gcloud.sh" \
  "${SCRIPTS_DIR}/migrate-state.sh" \
  "${SCRIPTS_DIR}/preflight.sh" \
  "${SCRIPTS_DIR}/repair-host.sh" \
  "${SCRIPTS_DIR}/rotate-app-secret.sh" \
  "${SCRIPTS_DIR}/run-agent.sh" \
  "${SCRIPTS_DIR}/setup-gcloud.sh" \
  "${SCRIPTS_DIR}/smoke-checks.sh" \
  "${SCRIPTS_DIR}/teardown-platform.sh"; do
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
  "GATEWAY_AUTO_DEPLOY=false"
  "GATEWAY_DISTR_PORTAL_NAME="
  "GATEWAY_CHART_VERSION=latest"
  "DISTR_DRY_RUN=0"
)

for line in "${required_env_lines[@]}"; do
  grep -Fxq "${line}" "${SAMPLE_ENV}" || {
    printf 'ERROR: sample environment is missing: %s\n' "${line}" >&2
    exit 1
  }
done

for secret_ref in \
  DISTR_TOKEN \
  DD_API_KEY \
  DD_APP_KEY \
  EXAMPLE_PROD_GATEWAY_GATEWAY_DASHBOARD_BOOTSTRAP_PASSWORD; do
  grep -Fq "{{.Secrets.${secret_ref}}}" "${SAMPLE_ENV}" || {
    printf 'ERROR: GCP sample does not match the AWS Hub secret contract: %s\n' \
      "${secret_ref}" >&2
    exit 1
  }
done

[[ ! -e "${BOOTSTRAP_DIR}/billing.tf" ]] || {
  printf 'ERROR: bootstrap must not manage a Cloud Billing budget\n' >&2
  exit 1
}
grep -Fq 'data "google_project" "environment"' \
  "${BOOTSTRAP_DIR}/projects.tf"
grep -Fq 'from = google_project.environment' \
  "${BOOTSTRAP_DIR}/projects.tf"
grep -Fq 'destroy = false' "${BOOTSTRAP_DIR}/projects.tf"
if grep -Fq 'resource "google_project" "environment"' \
  "${BOOTSTRAP_DIR}/projects.tf"; then
  printf 'ERROR: bootstrap must not create or own the selected project\n' >&2
  exit 1
fi
if grep -Eq 'gcloud[[:space:]]+projects[[:space:]]+create' \
  "${SCRIPTS_DIR}/install.sh"; then
  printf 'ERROR: installer must not create a GCP project\n' >&2
  exit 1
fi
grep -Fq 'resource "google_project_iam_member" "platform_dns"' \
  "${BOOTSTRAP_DIR}/iam.tf"
grep -Fq 'project = var.dns_project_id' \
  "${BOOTSTRAP_DIR}/iam.tf"
grep -Fq 'bootstrap_subnet_cidr must be a canonical RFC1918 /24' \
  "${BOOTSTRAP_DIR}/variables.tf"
grep -Eq '^[[:space:]]*project_id[[:space:]]*=[[:space:]]*var\.project_id$' \
  "${BOOTSTRAP_DIR}/projects.tf"
grep -Fq 'billing_project       = var.project_id' \
  "${BOOTSTRAP_DIR}/providers.tf"
grep -Fq 'user_project_override = true' "${BOOTSTRAP_DIR}/providers.tf"
if rg -n 'quota_project_id' \
  "${BOOTSTRAP_DIR}/variables.tf" "${BOOTSTRAP_DIR}/providers.tf" \
  "${BOOTSTRAP_DIR}/terraform.tfvars.example"; then
  printf 'ERROR: separate quota-project configuration remains\n' >&2
  exit 1
fi
if rg -n 'install_prompt_optional_candidate' "${SCRIPTS_DIR}/install.sh"; then
  printf 'ERROR: separate quota-project prompt remains\n' >&2
  exit 1
fi
# shellcheck disable=SC2016 # Match literal shell code in the implementation.
grep -Fq 'terraform -chdir="${TF_DIR}" apply -input=false "${PLAN_FILE}"' \
  "${SCRIPTS_DIR}/bootstrap.sh"
grep -Fq 'bootstrap refuses a plan containing resource deletions' \
  "${SCRIPTS_DIR}/bootstrap.sh"
grep -Fq 'install_archive_legacy_local_state' "${SCRIPTS_DIR}/install.sh"
grep -Fq 'bootstrap_wait_host_ready' "${SCRIPTS_DIR}/preflight.sh"
grep -Fq 'first-boot host setup did not become ready within 5 minutes' \
  "${SCRIPTS_DIR}/lib.sh"
for api in \
  cloudbilling.googleapis.com \
  cloudresourcemanager.googleapis.com \
  iam.googleapis.com \
  serviceusage.googleapis.com; do
  grep -Fq "${api}" "${SCRIPTS_DIR}/setup-gcloud.sh"
done
if rg -n -i 'billingbudgets|monthly_budget|google_billing_budget' \
  "${BOOTSTRAP_DIR}" --glob '*.tf' --glob 'terraform.tfvars.example'; then
  printf 'ERROR: billing budget configuration remains in the bootstrap\n' >&2
  exit 1
fi
if rg -n -i 'billingbudgets' \
  "${SCRIPTS_DIR}/setup-gcloud.sh" "${SCRIPTS_DIR}/preflight.sh"; then
  printf 'ERROR: billing budget API remains in the bootstrap scripts\n' >&2
  exit 1
fi
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
# The guided path reads one-time targetSecret material over stdin so it does
# not appear in shell history or child-process arguments.
grep -Fq 'IFS= read -r CONNECT_URL' "${SCRIPTS_DIR}/run-agent.sh"
grep -Fq 'IFS= read -r HUB_LINE' "${SCRIPTS_DIR}/connect-k8s-agent.sh"
grep -Fq 'run-agent.sh" --stdin' "${SCRIPTS_DIR}/install.sh"
grep -Fq 'connect-k8s-agent.sh" --stdin' "${SCRIPTS_DIR}/install.sh"
# shellcheck disable=SC2016 # Match literal shell code in the implementation.
grep -Fq '"${SCRIPT_DIR}/migrate-state.sh" --yes' \
  "${SCRIPTS_DIR}/bootstrap.sh"
git -C "${RUNBOOK_DIR}" check-ignore -q \
  api-gateway/gcp/.generated/gateway-infra.env
git -C "${RUNBOOK_DIR}" check-ignore -q \
  api-gateway/gcp/.generated/gateway-infra-auto-deploy.env
grep -Fq 'GENERATED_AUTO_DEPLOY_ENV=' "${SCRIPTS_DIR}/install.sh"
grep -Fq 'GATEWAY_AUTO_DEPLOY=true' "${SCRIPTS_DIR}/install.sh"

legacy_environment_label='sand''box'
if git -C "${RUNBOOK_DIR}" grep -qi "${legacy_environment_label}" \
  -- api-gateway/gcp; then
  printf 'ERROR: legacy environment terminology remains in the production-only GCP runbook\n' >&2
  exit 1
fi
legacy_example_brand='ac''me'
if git -C "${RUNBOOK_DIR}" grep -qi "${legacy_example_brand}" -- \
  api-gateway/gcp \
  api-gateway/sso-okta.md \
  api-gateway/sso-entra.md \
  FAQ.md; then
  printf 'ERROR: legacy customer example remains in the GCP installation surface\n' >&2
  exit 1
fi
# shellcheck disable=SC2016 # Match literal shell code in the implementation.
grep -Fq 'CLUSTER_NAME="${INFRA_DEPLOY_NAME}-gke"' \
  "${SCRIPTS_DIR}/teardown-platform.sh"

if grep -Eq '(BEGIN (RSA|OPENSSH|PRIVATE) KEY|\"type\"[[:space:]]*:[[:space:]]*\"service_account\")' \
  "${GCP_DIR}"/*.md "${GCP_DIR}"/*.env "${BOOTSTRAP_DIR}"/*.tf; then
  printf 'ERROR: key-like credential material found in GCP runbook\n' >&2
  exit 1
fi

printf '[test] OK: shell blocks, locked sample contract, and credential scan passed\n'
