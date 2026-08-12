#!/usr/bin/env bash
# Offline contract tests for the resumable guided GCP installer.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "${TEST_DIR}/.." && pwd)"
GCP_DIR="$(cd "${SCRIPTS_DIR}/../.." && pwd)"

# shellcheck source=../guided-install.sh
source "${SCRIPTS_DIR}/guided-install.sh"

TEST_ROOT="$(mktemp -d)"
test_cleanup() {
  local exit_status=$?
  rm -rf "${TEST_ROOT}"
  return "${exit_status}"
}
trap test_cleanup EXIT
BOOTSTRAP_DIR="${TEST_ROOT}/bootstrap"
mkdir -p "${BOOTSTRAP_DIR}"
CONFIG_FILE="${TEST_ROOT}/install.json"

jq '
  .deployments.infraApplicationId = "11111111-2222-4333-8444-555555555555"
  | .deployments.infraVersion = "infra-2026.08.12"
  | .deployments.gatewayVersion = "gateway-2026.08.12"
' "${GCP_DIR}/guided-install.json.example" >"${CONFIG_FILE}"

jq '.network.bootstrapSubnetCidr = "192.0.2.0/24"' \
  "${CONFIG_FILE}" >"${TEST_ROOT}/invalid-cidr.json"
if invalid_output="$(
  bash "${SCRIPTS_DIR}/guided-install.sh" \
    --config "${TEST_ROOT}/invalid-cidr.json" 2>&1
)"; then
  printf 'ERROR: guided installer accepted a non-RFC1918 bootstrap CIDR\n' >&2
  exit 1
fi
grep -Fq 'bootstrapSubnetCidr must be a canonical RFC1918 /24' \
  <<<"${invalid_output}"

guided_validate_config
guided_initialize_state
guided_write_bootstrap_vars
guided_write_infra_env 1

[[ "$(guided_state_get stage)" == "new" ]]
jq -e '
  .project_id == "acme-gateway-prod"
  and .dns_project_id == "acme-shared-dns"
  and .region == "us-east1"
  and .project_deletion_policy == "PREVENT"
  and .protect_bootstrap_vms == true
' "${BOOTSTRAP_VARS_FILE}" >/dev/null
grep -Fq "DISTR_TOKEN='{{.Secrets.ACME_GATEWAY_PROD_DISTR_TOKEN}}'" "${INFRA_ENV_FILE}"
grep -Fq "GATEWAY_AUTO_DEPLOY='false'" "${INFRA_ENV_FILE}"
grep -Fq "DISTR_DRY_RUN='1'" "${INFRA_ENV_FILE}"
if grep -Eq 'AccessToken|password-value|api-key-value' "${INFRA_ENV_FILE}"; then
  printf 'ERROR: generated infra environment contains secret material\n' >&2
  exit 1
fi

dotenv_probe="$(guided_dotenv_line SAFE_VALUE 'literal-$-value')"
[[ "${dotenv_probe}" == "SAFE_VALUE='literal-\$-value'" ]]
if guided_dotenv_line BAD_VALUE "can't-encode-this" >/dev/null 2>&1; then
  printf 'ERROR: guided installer accepted an unsafe dotenv value\n' >&2
  exit 1
fi

CAPTURE_FILE="${TEST_ROOT}/deployment.json"
guided_distr_request() {
  cp "$3" "${CAPTURE_FILE}"
}
printf 'gateway:\n  replicaCount: 2\n' >"${GATEWAY_VALUES_FILE}"
guided_put_deployment \
  "target-id" "version-id" "" "acme-prod-gateway" \
  "${GATEWAY_VALUES_FILE}" kubernetes
jq -e '
  .deploymentTargetId == "target-id"
  and .applicationVersionId == "version-id"
  and .releaseName == "acme-prod-gateway"
  and .forceRestart == true
  and .helmOptions.timeout == "15m"
  and .helmOptions.waitStrategy == "watcher"
  and .helmOptions.rollbackOnFailure == true
  and .helmOptions.cleanupOnFailure == true
' "${CAPTURE_FILE}" >/dev/null

guided_assert_dedicated_target \
  '{"deployments":[{"application":{"id":"app-id"}}]}' "app-id"
if guided_assert_dedicated_target \
  '{"deployments":[{"application":{"id":"other-app"}}]}' "app-id" \
  2>/dev/null; then
  printf 'ERROR: guided installer accepted a shared named target\n' >&2
  exit 1
fi

guided_state_set stage bootstrap_ready
cp "${CONFIG_FILE}" "${TEST_ROOT}/install.original.json"
jq '.dns.domainName = "changed.example.com"' \
  "${CONFIG_FILE}" >"${TEST_ROOT}/install.changed.json"
mv "${TEST_ROOT}/install.changed.json" "${CONFIG_FILE}"
if guided_initialize_state 2>/dev/null; then
  printf 'ERROR: guided installer accepted config drift after work began\n' >&2
  exit 1
fi
mv "${TEST_ROOT}/install.original.json" "${CONFIG_FILE}"
guided_initialize_state

terraform() {
  if [[ "$*" == *"output -raw project_id"* ]]; then
    printf 'acme-gateway-prod\n'
    return 0
  fi
  return 1
}
guided_state_set stage bootstrap_applying
guided_finish_bootstrap_apply
[[ "$(guided_state_get stage)" == "bootstrap_applied" ]]

RUNNER_MARKER='full platform apply intentionally paused'
guided_runner_logs() {
  printf '%s\n' "${RUNNER_MARKER}"
}
guided_state_set stage foundation_applying
guided_finish_foundation_apply
[[ "$(guided_state_get stage)" == "foundation_applied" ]]
RUNNER_MARKER='platform apply complete; idling for Distr Docker agent health'
guided_state_set stage platform_applying
guided_finish_platform_apply
[[ "$(guided_state_get stage)" == "platform_applied" ]]

guided_state_set infraTargetId target-id
guided_state_set infraVersionId version-id
guided_state_set infraDeploymentId deployment-id
guided_write_infra_env 0
EXPECTED_ENV_B64="$(guided_b64 <"${INFRA_ENV_FILE}")"
TARGET_ENV_B64="${EXPECTED_ENV_B64}"
guided_get_target() {
  jq -n --arg env "${TARGET_ENV_B64}" '{
    deployments:[{
      id:"deployment-id",applicationVersionId:"version-id",
      application:{id:"11111111-2222-4333-8444-555555555555"},
      envFileData:$env
    }]
  }'
}
guided_infra_revision_matches 0
TARGET_ENV_B64='different'
if guided_infra_revision_matches 0; then
  printf 'ERROR: guided installer accepted a different infra revision\n' >&2
  exit 1
fi

approval_count="$(grep -Ec 'guided_approve [1-5] ' "${SCRIPTS_DIR}/guided-install.sh")"
[[ "${approval_count}" -eq 5 ]] || {
  printf 'ERROR: expected exactly five guided approval calls, found %s\n' \
    "${approval_count}" >&2
  exit 1
}
for resumable_stage in \
  bootstrap_applying foundation_applying platform_applying gateway_deploying; do
  grep -Fq "\"\${stage}\" == \"${resumable_stage}\"" \
    "${SCRIPTS_DIR}/guided-install.sh" || {
      printf 'ERROR: guided installer does not resume stage %s\n' "${resumable_stage}" >&2
      exit 1
    }
done

printf '[test] OK: guided installer inputs, resume lock, payload, and five gates passed\n'
