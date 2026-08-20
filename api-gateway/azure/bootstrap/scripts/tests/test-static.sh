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
