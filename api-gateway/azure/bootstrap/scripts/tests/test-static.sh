#!/usr/bin/env bash
# Static checks for the Azure one-command bootstrap artifacts.
set -euo pipefail

AZURE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SCRIPT="${AZURE_DIR}/bootstrap/scripts/setup-azure.sh"
LIB="${AZURE_DIR}/bootstrap/scripts/lib.sh"

bash -n "${SCRIPT}" "${LIB}"

grep -Fq 'envFileData' "${LIB}"
grep -Fq 'dockerType: "compose"' "${LIB}"
grep -Fq 'protected-settings' "${LIB}"
grep -Fq -- '--argjson ts' "${LIB}"
grep -Fq 'DISTR_TARGET_CREATED' "${LIB}"
grep -Fq 'AZURE_DISTR_DOCKER_RECONNECT' "${SCRIPT}"
grep -Fq 'DISTR_DRY_RUN' "${LIB}"
grep -Fq 'DISTR_KUBERNETES_TARGET_AUTO_CONNECT=true' "${SCRIPT}"
grep -Fq 'GATEWAY_AUTO_DEPLOY=true' "${SCRIPT}"
grep -Fq 'DATADOG_ENABLED=false' "${SCRIPT}"
grep -Fq 'AZURE_MANAGED_REDIS_SKU:-Balanced_B1' "${SCRIPT}"
grep -Fq 'AZURE_MANAGED_REDIS_LOCATION' "${SCRIPT}"
grep -Fq 'MANAGED_REDIS_LOCATION="northcentralus"' "${SCRIPT}"
grep -Fq 'CLUSTER_ENDPOINT_PUBLIC_ACCESS=false' "${SCRIPT}"
grep -Fq 'az deployment sub create' "${SCRIPT}"
grep -Fq 'gateway-bootstrap-${LOCATION}' "${SCRIPT}"
grep -Fq 'az network dns zone list' "${LIB}"
grep -Fq 'Microsoft.ContainerService' "${LIB}"
grep -Fq 'Microsoft.PolicyInsights' "${LIB}"
grep -Fq 'supportedServerVersions' "${LIB}"

# Internal and customer-scoped targets may share a display name. Reusing a
# target from the wrong scope also resolves Hub Secrets from the wrong scope.
# shellcheck source=../lib.sh
source "${LIB}"
distr_api_request() {
  printf '%s\n' '[
    {"id":"internal-target","name":"same-name","type":"docker","customerOrganization":null},
    {"id":"customer-target","name":"same-name","type":"docker","customerOrganization":{"id":"customer-one"}}
  ]'
}
DISTR_DRY_RUN=0
unset DISTR_CUSTOMER_ORG_ID
test "$(distr_find_target_by_name same-name | jq -r '.id')" = "internal-target"
DISTR_CUSTOMER_ORG_ID=customer-one
test "$(distr_find_target_by_name same-name | jq -r '.id')" = "customer-target"
unset DISTR_CUSTOMER_ORG_ID

distr_api_request() {
  case "$1 $2" in
    'GET /deployment-targets') printf '[]\n' ;;
    'POST /deployment-targets') printf '{"id":"created-target","name":"new-name","type":"docker","deployments":[]}\n' ;;
    *) return 1 ;;
  esac
}
DISTR_TARGET_CREATED=0
distr_ensure_docker_target new-name CREATED_TARGET_JSON
test "${DISTR_TARGET_CREATED}" = "1"
test "$(jq -r '.id' <<<"${CREATED_TARGET_JSON}")" = "created-target"

DISTR_DRY_RUN=1
test "$(distr_request_target_access dry-run-target | jq -r '.connectUrl')" = \
  "https://example.invalid/distr-dry-run-agent"
DISTR_DRY_RUN=0

for file in \
  "${AZURE_DIR}/bootstrap/main.bicep" \
  "${AZURE_DIR}/bootstrap/resources.bicep"; do
  grep -Fq 'Microsoft.ManagedIdentity/userAssignedIdentities' "${AZURE_DIR}/bootstrap/resources.bicep"
  grep -Fq 'Microsoft.Compute/virtualMachines' "${AZURE_DIR}/bootstrap/resources.bicep"
  grep -Fq 'Microsoft.Storage/storageAccounts' "${AZURE_DIR}/bootstrap/resources.bicep"
  grep -Fq 'publicNetworkAccess' "${AZURE_DIR}/bootstrap/resources.bicep"
  grep -Fq 'User Access Administrator' "${AZURE_DIR}/bootstrap/main.bicep" || true
  test -s "${file}"
done

if grep -Eq 'connect-k8s-agent|kubectl apply -n|second infra deploy|GATEWAY_AUTO_DEPLOY=false' \
  "${AZURE_DIR}/instructions.md"; then
  echo "Azure instructions reintroduced the AWS/GCP manual K8s-agent or second-cycle flow" >&2
  exit 1
fi

echo "OK: Azure bootstrap static contract passed"
