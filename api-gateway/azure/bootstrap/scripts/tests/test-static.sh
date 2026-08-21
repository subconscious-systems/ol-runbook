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
grep -Fq 'DISTR_TARGET_CREATED' "${LIB}"
grep -Fq 'DISTR_DRY_RUN' "${LIB}"
grep -Fq 'DISTR_KUBERNETES_TARGET_AUTO_CONNECT=true' "${SCRIPT}"
grep -Fq 'GATEWAY_AUTO_DEPLOY=true' "${SCRIPT}"
grep -Fq 'DATADOG_ENABLED=false' "${SCRIPT}"
grep -Fq 'CLUSTER_ENDPOINT_PUBLIC_ACCESS=false' "${SCRIPT}"
grep -Fq 'az deployment sub create' "${SCRIPT}"
grep -Fq 'az network dns zone list' "${LIB}"
grep -Fq 'Microsoft.ContainerService' "${LIB}"
grep -Fq 'Microsoft.Quota' "${LIB}"
grep -Fq 'azgw_ensure_regional_vcpu_quota' "${SCRIPT}"
grep -Fq 'AZURE_MIN_REGIONAL_VCPUS:-24' "${SCRIPT}"
grep -Fq 'az quota update' "${LIB}"
grep -Fq -- '--resource-name cores' "${LIB}"

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
DISTR_DRY_RUN=1
test "$(distr_request_target_access dry-run-target | jq -r '.connectUrl')" = \
  "https://example.invalid/distr-dry-run-agent"
DISTR_DRY_RUN=0

azgw_assert_gateway_hostname_below_zone gateway.azure.example.com azure.example.com
if (azgw_assert_gateway_hostname_below_zone azure.example.com azure.example.com) >/dev/null 2>&1; then
  echo "Azure DNS validation accepted a zone-apex gateway hostname" >&2
  exit 1
fi

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
