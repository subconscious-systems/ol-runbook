#!/usr/bin/env bash
# Guided Azure gateway setup: one command, four normal prompts, Distr-owned agents.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

LOCATION="${AZURE_LOCATION:-eastus2}"
DNS_ZONE_ID="${AZURE_DNS_ZONE_ID:-}"
INFRA_APPLICATION_ID="${API_GATEWAY_INFRA_AZURE_APPLICATION_ID:-${DISTR_INFRA_APPLICATION_ID:-}}"
GATEWAY_APPLICATION_ID="${DISTR_GATEWAY_APPLICATION_ID:-df563de2-25e4-4d8b-b24c-53bb4ad11086}"
INFRA_VERSION_ID="${DISTR_INFRA_APPLICATION_VERSION_ID:-}"
GATEWAY_VERSION_TOKEN="${GATEWAY_CHART_VERSION:-latest}"
NO_WAIT=0
ASSUME_YES=0

usage() {
  cat >&2 <<'EOF'
usage: setup-azure.sh [options]

Normal path prompts for only:
  deploy slug, gateway hostname, provider DNS suffixes, Distr PAT.

Options:
  --location REGION
  --dns-zone RESOURCE_ID
  --infra-application-id UUID
  --infra-version-id UUID
  --gateway-application-id UUID
  --vnet-cidr CIDR
  --yes
  --no-wait
  --dry-run
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --location) LOCATION="$2"; shift 2 ;;
    --dns-zone) DNS_ZONE_ID="$2"; shift 2 ;;
    --infra-application-id) INFRA_APPLICATION_ID="$2"; shift 2 ;;
    --infra-version-id) INFRA_VERSION_ID="$2"; shift 2 ;;
    --gateway-application-id) GATEWAY_APPLICATION_ID="$2"; shift 2 ;;
    --vnet-cidr) VNET_CIDR="$2"; shift 2 ;;
    --yes) ASSUME_YES=1; shift ;;
    --no-wait) NO_WAIT=1; shift ;;
    --dry-run) DISTR_DRY_RUN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage; exit 2 ;;
  esac
done

for tool in az jq curl openssl python3 sed tr od cut ssh-keygen; do
  azgw_need "${tool}"
done

azgw_prompt DEPLOY_SLUG "Deployment slug, e.g. acme-prod"
DEPLOY_SLUG="$(azgw_slug "${DEPLOY_SLUG}")"
azgw_dns1123 "${DEPLOY_SLUG}" || azgw_die "deploy slug must produce a DNS-1123 label"

azgw_prompt GATEWAY_HOSTNAME "Gateway hostname, e.g. api.example.com"
GATEWAY_HOSTNAME="$(printf '%s' "${GATEWAY_HOSTNAME}" | tr '[:upper:]' '[:lower:]' | sed -E 's/[.]$//')"
[[ "${GATEWAY_HOSTNAME}" == *.* ]] || azgw_die "gateway hostname must be fully qualified"

azgw_prompt PROVIDER_SUFFIXES "Provider DNS suffix allowlist, comma-separated"
[[ -n "${PROVIDER_SUFFIXES}" ]] || azgw_die "provider suffix allowlist is required"

azgw_prompt_secret DISTR_TOKEN "Distr PAT"
[[ -n "${DISTR_TOKEN}" ]] || azgw_die "Distr PAT is required"

[[ -n "${INFRA_APPLICATION_ID}" ]] \
  || azgw_die "API_GATEWAY_INFRA_AZURE_APPLICATION_ID must be supplied by the vendor package or --infra-application-id"

azgw_log "startup gate 1/2: Azure identity"
azgw_ensure_azure_session
azgw_log "selected subscription ${AZURE_SUBSCRIPTION_ID}"

azgw_log "startup gate 2/2: Distr access and entitlements"
if [[ "${DISTR_DRY_RUN}" != "1" ]]; then
  distr_api_request GET "/applications/${INFRA_APPLICATION_ID}" >/dev/null
  distr_api_request GET "/applications/${GATEWAY_APPLICATION_ID}" >/dev/null
fi

azgw_resolve_dns_zone "${GATEWAY_HOSTNAME}" "${DNS_ZONE_ID}"
azgw_assert_gateway_hostname_below_zone "${GATEWAY_HOSTNAME}" "${DNS_ZONE_NAME}"
azgw_select_vnet_cidr

BOOTSTRAP_SUBNET_CIDR="$(
  python3 - "${VNET_CIDR}" <<'PY'
import ipaddress
import sys
network = ipaddress.ip_network(sys.argv[1], strict=True)
print(next(network.subnets(new_prefix=24)))
PY
)"

NAME_PREFIX="${DEPLOY_SLUG}"
DEPLOY_NAME="${DEPLOY_SLUG}-gw-infra"
GATEWAY_DEPLOY_NAME="${DEPLOY_SLUG}-gateway"
RESOURCE_GROUP_NAME="${DEPLOY_SLUG}-gateway"
VNET_NAME="${DEPLOY_SLUG}-gateway-vnet"
IDENTITY_NAME="${DEPLOY_SLUG}-gateway-runner"
VM_NAME="${DEPLOY_SLUG}-gw-bootstrap"
STATE_SUFFIX="$(azgw_hash8 "${AZURE_SUBSCRIPTION_ID}:${DEPLOY_SLUG}")"
STATE_STORAGE_ACCOUNT_NAME="$(printf 'ol%s%s' "$(printf '%s' "${DEPLOY_SLUG}" | tr -d '-')" "${STATE_SUFFIX}" | cut -c1-24)"
STATE_CONTAINER_NAME="tfstate"
SECRET_PREFIX="$(azgw_secret_key "${DEPLOY_SLUG}")"
BOOTSTRAP_PASSWORD_SECRET="${SECRET_PREFIX}_DASHBOARD_BOOTSTRAP_PASSWORD"
BOOTSTRAP_PASSWORD="${DASHBOARD_BOOTSTRAP_PASSWORD:-$(openssl rand -base64 24)}"
ACME_EMAIL="${AZURE_ACCOUNT_NAME}"
if [[ ! "${ACME_EMAIL}" =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ ]]; then
  ACME_EMAIL="ops@$(azgw_public_suffix "${GATEWAY_HOSTNAME}")"
fi

RUN_DIR="${AZGW_GENERATED_DIR}/${DEPLOY_SLUG}"
mkdir -p "${RUN_DIR}"
chmod 700 "${RUN_DIR}"
SSH_KEY="${RUN_DIR}/bootstrap_vm"
if [[ ! -f "${SSH_KEY}" ]]; then
  ssh-keygen -t ed25519 -N "" -C "orangeline-${DEPLOY_SLUG}" -f "${SSH_KEY}" >/dev/null
fi
ENV_FILE="${RUN_DIR}/azure-gateway-infra.env"

cat >"${ENV_FILE}" <<EOF
DISTR_TOKEN={{.Secrets.DISTR_TOKEN}}
DASHBOARD_BOOTSTRAP_PASSWORD={{.Secrets.${BOOTSTRAP_PASSWORD_SECRET}}}
DASHBOARD_OIDC_CLIENT_SECRET=
GATEWAY_WEBHOOK_SIGNING_SECRET=
CLOUD=azure
DEPLOY_NAME=${DEPLOY_NAME}
GATEWAY_DISTR_DEPLOYMENT_NAME=${GATEWAY_DEPLOY_NAME}
AZURE_SUBSCRIPTION_ID=${AZURE_SUBSCRIPTION_ID}
AZURE_TENANT_ID=${AZURE_TENANT_ID}
AZURE_LOCATION=${LOCATION}
AZURE_RESOURCE_GROUP=${RESOURCE_GROUP_NAME}
AZURE_VNET_NAME=${VNET_NAME}
AZURE_DNS_RESOURCE_GROUP=${DNS_ZONE_RESOURCE_GROUP}
AZURE_STATE_STORAGE_ACCOUNT=${STATE_STORAGE_ACCOUNT_NAME}
AZURE_STATE_CONTAINER=${STATE_CONTAINER_NAME}
AZURE_ACME_EMAIL=${ACME_EMAIL}
AZURE_PROJECT=api-gateway
DOMAIN_NAME=${GATEWAY_HOSTNAME}
DNS_ZONE_NAME=${DNS_ZONE_NAME}
AKS_MINIMUM_VERSION=1.36
VPC_CIDR=${VNET_CIDR}
CLUSTER_ENDPOINT_PUBLIC_ACCESS=false
CLUSTER_ENDPOINT_PUBLIC_ACCESS_CIDRS=
AZURE_POSTGRES_SKU=GP_Standard_D2ds_v5
AZURE_POSTGRES_STORAGE_MB=65536
AZURE_MANAGED_REDIS_SKU=Balanced_B3
DATADOG_ENABLED=false
DATADOG_SITE=datadoghq.com
DATADOG_ENV=${DEPLOY_SLUG}
GATEWAY_AUTO_DEPLOY=true
GATEWAY_CHART_VERSION=${GATEWAY_VERSION_TOKEN}
DISTR_GATEWAY_APPLICATION_ID=${GATEWAY_APPLICATION_ID}
DISTR_GATEWAY_APPLICATION_VERSION_ID=
DISTR_KUBERNETES_TARGET_AUTO_CONNECT=true
GATEWAY_ROUTE_ALLOWED_HOST_SUFFIXES=${PROVIDER_SUFFIXES}
GATEWAY_WEBHOOK_URL=
DASHBOARD_BOOTSTRAP_USERNAME=admin
DASHBOARD_BOOTSTRAP_ORG_NAME=${DEPLOY_SLUG}
DASHBOARD_BOOTSTRAP_FULL_NAME=Gateway Admin
DASHBOARD_OIDC_ENABLED=false
DASHBOARD_OIDC_PROVIDER=entra
DASHBOARD_OIDC_ISSUER_URL=
DASHBOARD_OIDC_CLIENT_ID=
DASHBOARD_OIDC_REDIRECT_URI=
DASHBOARD_OIDC_SCOPES=openid,email,profile
HOSTED_AUTH_ENABLED=false
GATEWAY_ADMIN_PUBLIC_INGRESS=false
GATEWAY_CONTROL_PLANE=self
HOSTED_AUTH_SERVICE_LABEL=
HOSTED_AUTH_SERVICE_PERMISSIONS=
HOSTED_AUTH_ADMIN_ISSUER=
HOSTED_AUTH_ADMIN_JWKS_URL=
HOSTED_AUTH_SERVICE_SUBJECT=
DISTR_DRY_RUN=0
EOF
chmod 600 "${ENV_FILE}"

if [[ "${ASSUME_YES}" != "1" && "${DISTR_DRY_RUN}" != "1" ]]; then
  cat >&2 <<EOF

Azure gateway setup will create or update:
  Resource group: ${RESOURCE_GROUP_NAME}
  Bootstrap VM:   ${VM_NAME}
  VNet:           ${VNET_NAME} (${VNET_CIDR})
  DNS zone:       ${DNS_ZONE_NAME} (${DNS_ZONE_RESOURCE_GROUP})
  Hostname:       https://${GATEWAY_HOSTNAME}/dashboard

EOF
  printf 'Type %s to continue: ' "${DEPLOY_SLUG}" >&2
  read -r confirmation
  [[ "${confirmation}" == "${DEPLOY_SLUG}" ]] || azgw_die "cancelled"
fi

azgw_register_providers
azgw_ensure_regional_vcpu_quota "${LOCATION}" "${AZURE_MIN_REGIONAL_VCPUS:-24}"

azgw_log "deploying Azure bootstrap foundation"
if [[ "${DISTR_DRY_RUN}" == "1" ]]; then
  azgw_log "DRY_RUN would run az deployment sub create"
else
  az deployment sub create \
    --name "${DEPLOY_SLUG}-gateway-bootstrap" \
    --location "${LOCATION}" \
    --template-file "${AZGW_BOOTSTRAP_DIR}/main.bicep" \
    --parameters \
      location="${LOCATION}" \
      resourceGroupName="${RESOURCE_GROUP_NAME}" \
      namePrefix="${DEPLOY_SLUG}" \
      virtualNetworkName="${VNET_NAME}" \
      vnetCidr="${VNET_CIDR}" \
      bootstrapSubnetCidr="${BOOTSTRAP_SUBNET_CIDR}" \
      stateStorageAccountName="${STATE_STORAGE_ACCOUNT_NAME}" \
      stateContainerName="${STATE_CONTAINER_NAME}" \
      identityName="${IDENTITY_NAME}" \
      vmName="${VM_NAME}" \
      sshPublicKey="$(<"${SSH_KEY}.pub")" \
      dnsZoneName="${DNS_ZONE_NAME}" \
      dnsZoneResourceGroupName="${DNS_ZONE_RESOURCE_GROUP}" \
    --output none \
    --only-show-errors
fi

azgw_log "creating scoped Hub Secrets"
distr_upsert_secret "DISTR_TOKEN" "${DISTR_TOKEN}"
distr_upsert_secret "${BOOTSTRAP_PASSWORD_SECRET}" "${BOOTSTRAP_PASSWORD}"

azgw_log "resolving infra application version"
if [[ -z "${INFRA_VERSION_ID}" ]]; then
  latest="$(distr_application_latest_version "${INFRA_APPLICATION_ID}")"
  INFRA_VERSION_ID="${latest%%$'\t'*}"
  azgw_log "using latest infra version ${latest#*$'\t'}"
fi

azgw_log "creating or reusing Distr Docker target and deployment"
TARGET_JSON="$(distr_ensure_docker_target "${DEPLOY_NAME}")"
distr_put_docker_deployment "${TARGET_JSON}" "${INFRA_VERSION_ID}" "${ENV_FILE}"
TARGET_ID="$(jq -r '.id' <<<"${TARGET_JSON}")"

if jq -e '.reportedAgentVersionId != null' <<<"${TARGET_JSON}" >/dev/null; then
  azgw_log "Distr Docker target already connected"
else
  if [[ "$(jq -r '.id' <<<"${TARGET_JSON}")" != "dry-run-target" \
    && "${DISTR_TARGET_CREATED:-0}" != "1" \
    && -n "$(jq -r '.createdAt // empty' <<<"${TARGET_JSON}")" \
    && "${AZURE_DISTR_DOCKER_RECONNECT:-false}" != "true" ]]; then
    azgw_die "Docker target exists but is disconnected; rerun with AZURE_DISTR_DOCKER_RECONNECT=true to rotate and reinstall its credential"
  fi
  ACCESS_JSON="$(distr_request_target_access "${TARGET_ID}")"
  CONNECT_URL="$(jq -er '.connectUrl' <<<"${ACCESS_JSON}")"
  azgw_install_docker_agent "${CONNECT_URL}"
fi

azgw_wait_distr_deployment "${TARGET_ID}" "${INFRA_APPLICATION_ID}"

cat <<EOF

Azure gateway setup is running through Distr.

Dashboard:
  https://${GATEWAY_HOSTNAME}/dashboard

Generated support files:
  ${ENV_FILE}

Initial dashboard password was stored in Hub Secret:
  ${BOOTSTRAP_PASSWORD_SECRET}

If the final readiness wait was skipped, watch the api-gateway-infra deployment
in Distr. The runner will create the AKS Kubernetes target, deploy the gateway,
and verify public /healthz and /readyz before reporting healthy.
EOF
