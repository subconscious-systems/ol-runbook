#!/usr/bin/env bash
# Resumable five-approval production installer for the GCP API Gateway.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BOOTSTRAP_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

CONFIG_FILE=""
INSTALL_STATE_DIR=""
INSTALL_STATE_FILE=""
BOOTSTRAP_VARS_FILE=""
INFRA_ENV_FILE=""
GATEWAY_VALUES_FILE=""
INSTALL_LOCK_DIR=""
INSTALL_LOCK_OWNED=0
INSTALL_DISTR_TOKEN=""
HUB_SECRET_PREFIX=""
HUB_DISTR_TOKEN_SECRET=""
HUB_DD_API_KEY_SECRET=""
HUB_DD_APP_KEY_SECRET=""
HUB_DASHBOARD_PASSWORD_SECRET=""
GUIDED_WAIT_SECONDS="${GUIDED_WAIT_SECONDS:-7200}"
GUIDED_POLL_SECONDS="${GUIDED_POLL_SECONDS:-15}"
GUIDED_ACCEPTANCE_POLL_SECONDS="${GUIDED_ACCEPTANCE_POLL_SECONDS:-60}"
readonly DISTR_API_BASE="https://app.distr.sh/api/v1"
SENSITIVE_TEMP_FILES=()

guided_cleanup() {
  local exit_status=$?
  if [[ "${#SENSITIVE_TEMP_FILES[@]}" -gt 0 ]]; then
    rm -f -- "${SENSITIVE_TEMP_FILES[@]}"
  fi
  if [[ "${INSTALL_LOCK_OWNED}" -eq 1 && -n "${INSTALL_LOCK_DIR}" \
    && -d "${INSTALL_LOCK_DIR}" ]]; then
    rm -f -- "${INSTALL_LOCK_DIR}/pid" || true
    rmdir "${INSTALL_LOCK_DIR}" 2>/dev/null || true
  fi
  return "${exit_status}"
}

trap guided_cleanup EXIT
trap 'guided_cleanup; exit 129' HUP
trap 'guided_cleanup; exit 130' INT
trap 'guided_cleanup; exit 143' TERM

guided_usage() {
  cat >&2 <<'EOF'
usage: guided-install.sh --config FILE

Runs or resumes one production GCP installation with five typed approvals:
  1. project/bootstrap foundation
  2. cloud platform foundation
  3. complete in-cluster platform
  4. gateway Helm deployment
  5. production acceptance

Start by copying ../../guided-install.json.example. The installer stores only
generated non-secret inputs and Distr resource IDs under .guided-install/.
Secrets use hidden prompts and short-lived mode-0600 request files that are
deleted immediately and by the exit trap; installer state never retains them.
EOF
}

guided_log() {
  printf '[guided-install] %s\n' "$*" >&2
}

guided_die() {
  guided_log "ERROR: $*"
  return 1
}

guided_need() {
  command -v "$1" >/dev/null 2>&1 || guided_die "$1 is required"
}

guided_sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum | awk '{print $1}'
  else
    shasum -a 256 | awk '{print $1}'
  fi
}

guided_sensitive_temp() {
  local prefix="$1"
  local output_name="$2"
  local path
  path="$(mktemp "${INSTALL_STATE_DIR}/${prefix}.XXXXXX")"
  chmod 600 "${path}"
  SENSITIVE_TEMP_FILES+=("${path}")
  printf -v "${output_name}" '%s' "${path}"
}

guided_json_value() {
  jq -r "$1" "${CONFIG_FILE}"
}

guided_state_get() {
  jq -er --arg key "$1" '.[$key] // empty' "${INSTALL_STATE_FILE}" 2>/dev/null || true
}

guided_state_set() {
  local key="$1"
  local value="$2"
  local state_tmp="${INSTALL_STATE_FILE}.tmp"
  jq --arg key "${key}" --arg value "${value}" \
    '.[$key] = $value' "${INSTALL_STATE_FILE}" >"${state_tmp}"
  chmod 600 "${state_tmp}"
  mv -f "${state_tmp}" "${INSTALL_STATE_FILE}"
}

guided_b64() {
  if base64 --help 2>&1 | grep -q -- '-w'; then
    base64 -w 0
  else
    base64 | tr -d '\n'
  fi
}

guided_dotenv_line() {
  local key="$1"
  local value="$2"
  if [[ "${value}" == *$'\n'* || "${value}" == *$'\r'* || "${value}" == *"'"* ]]; then
    guided_die "${key} contains a character that cannot be safely encoded in a dotenv file"
    return 1
  fi
  printf "%s='%s'\n" "${key}" "${value}"
}

guided_validate_config() {
  local billing_account_upper
  jq -e '
    (.project.id | type == "string" and length > 0)
    and (.project.name | type == "string" and length >= 4)
    and (.project.billingAccountId | type == "string" and length > 0)
    and (.project.monthlyBudgetUsd | type == "number" and . > 0 and floor == .)
    and (.project.operatorPrincipals | type == "array" and length > 0 and all(.[]; type == "string"))
    and ((.project.quotaProjectId // "") | type == "string")
    and (.network.bootstrapZone | type == "string" and length > 0)
    and (.network.bootstrapSubnetCidr | type == "string" and length > 0)
    and (.network.platformVpcCidr | type == "string" and length > 0)
    and (.dns.projectId | type == "string" and length > 0)
    and (.dns.zoneName | type == "string" and length > 0)
    and (.dns.domainName | type == "string" and length > 0)
    and (.deployments.infraName | type == "string")
    and (.deployments.infraApplicationId | type == "string")
    and (.deployments.infraVersion | type == "string")
    and (.deployments.gatewayName | type == "string")
    and (.deployments.gatewayApplicationId | type == "string")
    and (.deployments.gatewayVersion | type == "string")
    and (.deployments.routeAllowedHostSuffixes | type == "array" and length > 0 and all(.[]; type == "string"))
    and (.observability.datadogEnabled | type == "boolean")
    and ((.observability.datadogSite // "datadoghq.com") | type == "string")
    and (.dashboard.bootstrapAdmin | type == "boolean")
    and ((.dashboard.username // "admin") | type == "string")
    and ((.dashboard.organizationName // "Gateway Organization") | type == "string")
    and ((.dashboard.fullName // "Gateway Admin") | type == "string")
  ' "${CONFIG_FILE}" >/dev/null || guided_die "config is missing required fields or types"

  PROJECT_ID="$(guided_json_value '.project.id')"
  PROJECT_NAME="$(guided_json_value '.project.name')"
  ORGANIZATION_ID="$(jq -r '.project.organizationId // ""' "${CONFIG_FILE}")"
  FOLDER_ID="$(jq -r '.project.folderId // ""' "${CONFIG_FILE}")"
  BILLING_ACCOUNT_ID="$(guided_json_value '.project.billingAccountId')"
  QUOTA_PROJECT_ID="$(jq -r '.project.quotaProjectId // ""' "${CONFIG_FILE}")"
  MONTHLY_BUDGET_USD="$(guided_json_value '.project.monthlyBudgetUsd')"
  BOOTSTRAP_ZONE="$(guided_json_value '.network.bootstrapZone')"
  BOOTSTRAP_SUBNET_CIDR="$(guided_json_value '.network.bootstrapSubnetCidr')"
  PLATFORM_VPC_CIDR="$(guided_json_value '.network.platformVpcCidr')"
  DNS_PROJECT_ID="$(guided_json_value '.dns.projectId')"
  DNS_ZONE_NAME="$(guided_json_value '.dns.zoneName')"
  DOMAIN_NAME="$(guided_json_value '.dns.domainName')"
  INFRA_NAME="$(guided_json_value '.deployments.infraName')"
  INFRA_APPLICATION_ID="$(guided_json_value '.deployments.infraApplicationId')"
  INFRA_VERSION="$(guided_json_value '.deployments.infraVersion')"
  GATEWAY_NAME="$(guided_json_value '.deployments.gatewayName')"
  GATEWAY_APPLICATION_ID="$(guided_json_value '.deployments.gatewayApplicationId')"
  GATEWAY_VERSION="$(guided_json_value '.deployments.gatewayVersion')"
  ROUTE_SUFFIXES="$(jq -r '.deployments.routeAllowedHostSuffixes | join(",")' "${CONFIG_FILE}")"
  DATADOG_ENABLED="$(guided_json_value '.observability.datadogEnabled')"
  DATADOG_SITE="$(jq -r '.observability.datadogSite // "datadoghq.com"' "${CONFIG_FILE}")"
  DASHBOARD_BOOTSTRAP="$(guided_json_value '.dashboard.bootstrapAdmin')"
  DASHBOARD_USERNAME="$(jq -r '.dashboard.username // "admin"' "${CONFIG_FILE}")"
  DASHBOARD_ORG_NAME="$(jq -r '.dashboard.organizationName // "Gateway Organization"' "${CONFIG_FILE}")"
  DASHBOARD_FULL_NAME="$(jq -r '.dashboard.fullName // "Gateway Admin"' "${CONFIG_FILE}")"

  [[ "${PROJECT_ID}" =~ ^[a-z][a-z0-9-]{4,28}[a-z0-9]$ ]] \
    || guided_die "project.id is not a valid Google Cloud project ID"
  [[ "${#PROJECT_NAME}" -le 30 ]] \
    || guided_die "project.name must be at most 30 characters"
  [[ "${DNS_PROJECT_ID}" =~ ^[a-z][a-z0-9-]{4,28}[a-z0-9]$ ]] \
    || guided_die "dns.projectId is not a valid Google Cloud project ID"
  [[ "${DNS_PROJECT_ID}" != "${PROJECT_ID}" ]] \
    || guided_die "dns.projectId must be the existing shared DNS project, not the new gateway project"
  if ! { [[ "${ORGANIZATION_ID}" =~ ^[0-9]+$ && -z "${FOLDER_ID}" ]] \
    || [[ "${FOLDER_ID}" =~ ^[0-9]+$ && -z "${ORGANIZATION_ID}" ]]; }; then
    guided_die "set exactly one numeric project.organizationId or project.folderId"
  fi
  billing_account_upper="$(printf '%s' "${BILLING_ACCOUNT_ID}" | tr '[:lower:]' '[:upper:]')"
  [[ "${billing_account_upper}" =~ ^[0-9A-F]{6}-[0-9A-F]{6}-[0-9A-F]{6}$ ]] \
    || guided_die "project.billingAccountId is invalid"
  [[ "${BOOTSTRAP_ZONE}" =~ ^us-east1-[a-z]$ ]] \
    || guided_die "network.bootstrapZone must be in us-east1"
  bootstrap_assert_dns1123 "${INFRA_NAME}" "deployments.infraName"
  bootstrap_assert_dns1123 "${GATEWAY_NAME}" "deployments.gatewayName"
  [[ "${INFRA_NAME}" != "${GATEWAY_NAME}" ]] \
    || guided_die "infraName and gatewayName must be different"
  [[ "${#INFRA_NAME}" -le 32 && "${#GATEWAY_NAME}" -le 32 ]] \
    || guided_die "Distr deployment names must be at most 32 characters"
  [[ "${DOMAIN_NAME}" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ \
    && "${DOMAIN_NAME}" == *.* ]] || guided_die "dns.domainName is invalid"
  [[ "${DOMAIN_NAME}" != *[A-Z]* ]] \
    || guided_die "dns.domainName must be lowercase"
  for application_id in "${INFRA_APPLICATION_ID}" "${GATEWAY_APPLICATION_ID}"; do
    [[ "${application_id}" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]] \
      || guided_die "Distr application IDs must be UUIDs"
  done
  for release in "${INFRA_VERSION}" "${GATEWAY_VERSION}"; do
    [[ -n "${release}" && "${release}" != latest && "${release}" != nochange \
      && "${release}" != REPLACE_* ]] \
      || guided_die "infraVersion and gatewayVersion must be exact pinned version names"
  done
  case "${DATADOG_SITE}" in
    datadoghq.com|datadoghq.eu|us3.datadoghq.com|us5.datadoghq.com|\
    ap1.datadoghq.com|ap2.datadoghq.com|ddog-gov.com|us2.ddog-gov.com|\
    uk1.datadoghq.com|datad0g.com) ;;
    *) guided_die "observability.datadogSite is not supported" ;;
  esac
  local route_suffix
  while IFS= read -r route_suffix; do
    [[ "${route_suffix}" =~ ^\.?[a-z0-9]([a-z0-9.-]*[a-z0-9])?$ \
      && "${route_suffix}" == *.* \
      && "${route_suffix}" != ".svc.cluster.local" \
      && "${route_suffix}" != "svc.cluster.local" ]] \
      || guided_die "each routeAllowedHostSuffixes entry must be a lowercase external DNS suffix"
  done < <(jq -r '.deployments.routeAllowedHostSuffixes[]' "${CONFIG_FILE}")
  python3 - "${BOOTSTRAP_SUBNET_CIDR}" "${PLATFORM_VPC_CIDR}" <<'PY' || return 1
import ipaddress
import sys

bootstrap = ipaddress.ip_network(sys.argv[1], strict=True)
platform = ipaddress.ip_network(sys.argv[2], strict=True)
rfc1918 = tuple(
    ipaddress.ip_network(cidr)
    for cidr in ("10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16")
)


def is_rfc1918(network):
    return network.version == 4 and any(network.subnet_of(block) for block in rfc1918)


if not is_rfc1918(bootstrap) or bootstrap.prefixlen != 24:
    raise SystemExit("bootstrapSubnetCidr must be a canonical RFC1918 /24")
if not is_rfc1918(platform) or platform.prefixlen != 16:
    raise SystemExit("platformVpcCidr must be a canonical RFC1918 /16")
if bootstrap.overlaps(platform):
    raise SystemExit("bootstrap and platform CIDRs overlap")
PY

  HUB_SECRET_PREFIX="$(printf '%s' "${PROJECT_ID}" | tr '[:lower:]-' '[:upper:]_')"
  HUB_DISTR_TOKEN_SECRET="${HUB_SECRET_PREFIX}_DISTR_TOKEN"
  HUB_DD_API_KEY_SECRET="${HUB_SECRET_PREFIX}_DD_API_KEY"
  HUB_DD_APP_KEY_SECRET="${HUB_SECRET_PREFIX}_DD_APP_KEY"
  HUB_DASHBOARD_PASSWORD_SECRET="${HUB_SECRET_PREFIX}_GATEWAY_DASHBOARD_BOOTSTRAP_PASSWORD"
}

guided_initialize_state() {
  local config_digest saved_digest stage lock_pid
  INSTALL_STATE_DIR="${BOOTSTRAP_DIR}/.guided-install/${PROJECT_ID}"
  INSTALL_STATE_FILE="${INSTALL_STATE_DIR}/state.json"
  BOOTSTRAP_VARS_FILE="${INSTALL_STATE_DIR}/bootstrap.tfvars.json"
  INFRA_ENV_FILE="${INSTALL_STATE_DIR}/infra.env"
  GATEWAY_VALUES_FILE="${INSTALL_STATE_DIR}/gateway-values.yaml"
  mkdir -p "${INSTALL_STATE_DIR}"
  chmod 700 "${BOOTSTRAP_DIR}/.guided-install" "${INSTALL_STATE_DIR}"
  INSTALL_LOCK_DIR="${INSTALL_STATE_DIR}/lock"
  lock_pid="$(command cat "${INSTALL_LOCK_DIR}/pid" 2>/dev/null || true)"
  if [[ "${INSTALL_LOCK_OWNED}" -eq 1 && "${lock_pid}" == "$$" ]]; then
    :
  elif mkdir "${INSTALL_LOCK_DIR}" 2>/dev/null; then
    INSTALL_LOCK_OWNED=1
  else
    lock_pid="$(command cat "${INSTALL_LOCK_DIR}/pid" 2>/dev/null || true)"
    if [[ "${lock_pid}" =~ ^[1-9][0-9]*$ ]] && kill -0 "${lock_pid}" 2>/dev/null; then
      guided_die "another guided installer is already running for ${PROJECT_ID} (PID ${lock_pid})"
      return 1
    fi
    rm -f -- "${INSTALL_LOCK_DIR}/pid"
    rmdir "${INSTALL_LOCK_DIR}" 2>/dev/null \
      || guided_die "could not clear the stale installer lock at ${INSTALL_LOCK_DIR}"
    mkdir "${INSTALL_LOCK_DIR}"
    INSTALL_LOCK_OWNED=1
  fi
  printf '%s\n' "$$" >"${INSTALL_LOCK_DIR}/pid"
  chmod 600 "${INSTALL_LOCK_DIR}/pid"
  find "${INSTALL_STATE_DIR}" -maxdepth 1 -type f \
    \( -name 'distr-auth.*' -o -name 'distr-response.*' \
      -o -name 'distr-secret.*' -o -name 'distr-target.*' \
      -o -name 'distr-deployment.*' \) \
    -exec rm -f -- {} +
  if [[ ! -f "${INSTALL_STATE_FILE}" ]]; then
    config_digest="$(jq -Sc . "${CONFIG_FILE}" | guided_sha256)"
    jq -n --arg projectId "${PROJECT_ID}" --arg configDigest "${config_digest}" \
      '{stage:"new", projectId:$projectId, configDigest:$configDigest}' \
      >"${INSTALL_STATE_FILE}"
    chmod 600 "${INSTALL_STATE_FILE}"
  fi
  [[ "$(guided_state_get projectId)" == "${PROJECT_ID}" ]] \
    || guided_die "installer state belongs to another project"
  config_digest="$(jq -Sc . "${CONFIG_FILE}" | guided_sha256)"
  saved_digest="$(guided_state_get configDigest)"
  stage="$(guided_state_get stage)"
  if [[ "${stage}" == "new" ]]; then
    guided_state_set configDigest "${config_digest}"
  elif [[ -z "${saved_digest}" || "${saved_digest}" != "${config_digest}" ]]; then
    guided_die "config changed after installation began; restore the reviewed config before resuming"
  fi
}

guided_write_bootstrap_vars() {
  jq -n \
    --arg organization_id "${ORGANIZATION_ID}" \
    --arg folder_id "${FOLDER_ID}" \
    --arg billing_account_id "${BILLING_ACCOUNT_ID}" \
    --arg quota_project_id "${QUOTA_PROJECT_ID}" \
    --arg project_id "${PROJECT_ID}" \
    --arg project_name "${PROJECT_NAME}" \
    --arg dns_project_id "${DNS_PROJECT_ID}" \
    --argjson monthly_budget_amount_usd "${MONTHLY_BUDGET_USD}" \
    --arg bootstrap_zone "${BOOTSTRAP_ZONE}" \
    --arg bootstrap_subnet_cidr "${BOOTSTRAP_SUBNET_CIDR}" \
    --argjson operator_principals "$(jq '.project.operatorPrincipals' "${CONFIG_FILE}")" \
    '{
      organization_id: $organization_id,
      folder_id: $folder_id,
      billing_account_id: $billing_account_id,
      quota_project_id: $quota_project_id,
      project_id: $project_id,
      project_name: $project_name,
      dns_project_id: $dns_project_id,
      monthly_budget_amount_usd: $monthly_budget_amount_usd,
      region: "us-east1",
      bootstrap_zone: $bootstrap_zone,
      bootstrap_subnet_cidr: $bootstrap_subnet_cidr,
      bootstrap_machine_type: "e2-standard-2",
      bootstrap_disk_size_gb: 40,
      operator_principals: $operator_principals,
      project_deletion_policy: "PREVENT",
      protect_bootstrap_vms: true,
      labels: {
        application: "subconscious-gateway",
        "managed-by": "terraform",
        owner: "platform"
      }
    }' >"${BOOTSTRAP_VARS_FILE}"
  chmod 600 "${BOOTSTRAP_VARS_FILE}"
}

guided_approve() {
  local gate="$1"
  local description="$2"
  local expected="APPROVE GATE ${gate} ${PROJECT_ID}"
  local confirmation=""
  [[ -t 0 ]] || guided_die "approval gate ${gate} requires an interactive terminal"
  printf '\nApproval gate %s: %s\n' "${gate}" "${description}" >&2
  printf 'Type exactly: %s\n> ' "${expected}" >&2
  read -r confirmation
  [[ "${confirmation}" == "${expected}" ]] || guided_die "gate ${gate} was not approved"
}

guided_ensure_google_auth() {
  if ! command -v gcloud >/dev/null 2>&1 \
    || ! command -v gke-gcloud-auth-plugin >/dev/null 2>&1; then
    guided_log "installing the Google Cloud CLI and GKE authentication plugin"
    "${SCRIPT_DIR}/install-gcloud.sh"
  fi
  if ! gcloud auth application-default print-access-token >/dev/null 2>&1 \
    || [[ -z "$(gcloud auth list --filter=status:ACTIVE --format='value(account)' 2>/dev/null | head -n1)" ]]; then
    guided_log "Google user and Application Default Credentials login required"
    if [[ -n "${QUOTA_PROJECT_ID}" ]]; then
      "${SCRIPT_DIR}/setup-gcloud.sh" --quota-project "${QUOTA_PROJECT_ID}"
    else
      "${SCRIPT_DIR}/setup-gcloud.sh"
    fi
  fi
}

guided_gate_one() {
  local zone_dns_name normalized_zone
  guided_log "validating DNS zone before any production project apply"
  zone_dns_name="$(
    gcloud dns managed-zones describe "${DNS_ZONE_NAME}" \
      --project="${DNS_PROJECT_ID}" \
      --format='value(dnsName)'
  )"
  normalized_zone="${zone_dns_name%.}"
  [[ -n "${normalized_zone}" \
    && ( "${DOMAIN_NAME}" == "${normalized_zone}" \
      || "${DOMAIN_NAME}" == *."${normalized_zone}" ) ]] \
    || guided_die "dns.domainName is not inside the selected managed zone ${zone_dns_name:-unknown}"

  printf '\nProduction installation inputs\n' >&2
  jq '{project, network, dns, deployments, observability, dashboard}' \
    "${CONFIG_FILE}" >&2
  "${SCRIPT_DIR}/bootstrap.sh" --plan --var-file "${BOOTSTRAP_VARS_FILE}"
  guided_approve 1 "apply the exact project and private bootstrap foundation plan"
  guided_state_set stage "bootstrap_applying"
  guided_finish_bootstrap_apply
}

guided_finish_bootstrap_apply() {
  local applied_project
  if [[ -f "${BOOTSTRAP_DIR}/.bootstrap.tfplan" ]]; then
    if ! "${SCRIPT_DIR}/bootstrap.sh" --apply --yes; then
      guided_state_set stage "new"
      guided_die "bootstrap apply did not complete; rerun to create and approve a fresh exact plan"
      return 1
    fi
  else
    applied_project="$(terraform -chdir="${BOOTSTRAP_DIR}" output -raw project_id 2>/dev/null || true)"
    [[ "${applied_project}" == "${PROJECT_ID}" ]] || {
      guided_state_set stage "new"
      guided_die "bootstrap plan is gone and the approved project is not present; rerun to create a fresh plan"
      return 1
    }
  fi
  guided_state_set stage "bootstrap_applied"
}

guided_finish_bootstrap() {
  if [[ ! -f "${BOOTSTRAP_DIR}/backend.tf" ]]; then
    "${SCRIPT_DIR}/migrate-state.sh" --yes
  else
    [[ -f "${BOOTSTRAP_DIR}/.backend.hcl" ]] \
      || guided_die "backend.tf exists without .backend.hcl; restore the reviewed backend configuration"
    terraform -chdir="${BOOTSTRAP_DIR}" init -input=false -reconfigure \
      -backend-config=.backend.hcl
  fi
  local plan_rc=0
  terraform -chdir="${BOOTSTRAP_DIR}" plan -input=false -detailed-exitcode \
    -var-file="${BOOTSTRAP_VARS_FILE}" >/dev/null || plan_rc=$?
  [[ "${plan_rc}" -eq 0 ]] \
    || guided_die "bootstrap state migration did not produce an empty plan"
  local service_account attempts_remaining=12
  service_account="$(terraform -chdir="${BOOTSTRAP_DIR}" output -raw bootstrap_service_account)"
  until gcloud projects get-iam-policy "${DNS_PROJECT_ID}" --format=json \
    | jq -e --arg member "serviceAccount:${service_account}" \
      'any(.bindings[]?; .role == "roles/dns.admin" and any(.members[]?; . == $member))' \
      >/dev/null; do
    attempts_remaining=$((attempts_remaining - 1))
    [[ "${attempts_remaining}" -gt 0 ]] \
      || guided_die "platform service account did not receive DNS administration in ${DNS_PROJECT_ID}"
    guided_log "waiting for shared DNS IAM propagation"
    sleep 5
  done
  "${SCRIPT_DIR}/preflight.sh"
  "${SCRIPT_DIR}/repair-host.sh"
  guided_state_set stage "bootstrap_ready"
}

guided_prompt_secret() {
  local prompt="$1"
  local output_name="$2"
  local first=""
  local second=""
  [[ -t 0 ]] || guided_die "secret prompts require an interactive terminal"
  printf '%s: ' "${prompt}" >&2
  IFS= read -r -s first
  printf '\nConfirm %s: ' "${prompt}" >&2
  IFS= read -r -s second
  printf '\n' >&2
  [[ -n "${first}" && "${first}" == "${second}" ]] \
    || guided_die "secret values were empty or did not match"
  printf -v "${output_name}" '%s' "${first}"
}

guided_ensure_distr_token() {
  if [[ -z "${INSTALL_DISTR_TOKEN}" ]]; then
    guided_prompt_secret "Distr customer PAT" INSTALL_DISTR_TOKEN
  fi
  [[ "${INSTALL_DISTR_TOKEN}" != *$'\n'* \
    && "${INSTALL_DISTR_TOKEN}" != *$'\r'* \
    && "${INSTALL_DISTR_TOKEN}" != *'"'* \
    && "${INSTALL_DISTR_TOKEN}" != *\\* \
    && "${INSTALL_DISTR_TOKEN}" != *"'"* ]] \
    || guided_die "Distr PAT contains a character that cannot be safely passed to curl"
}

guided_distr_request() {
  local method="$1"
  local endpoint="$2"
  local body_file="${3:-}"
  local auth_file response_file status
  guided_sensitive_temp distr-auth auth_file
  guided_sensitive_temp distr-response response_file
  {
    printf 'header = "Accept: application/json"\n'
    printf 'header = "Authorization: AccessToken %s"\n' "${INSTALL_DISTR_TOKEN}"
  } >"${auth_file}"
  local curl_args=(
    --silent --show-error
    --config "${auth_file}"
    --request "${method}"
    --output "${response_file}"
    --write-out '%{http_code}'
  )
  if [[ -n "${body_file}" ]]; then
    curl_args+=(--header 'Content-Type: application/json' --data-binary "@${body_file}")
  fi
  status="$(curl "${curl_args[@]}" "${DISTR_API_BASE}${endpoint}")" || status="000"
  rm -f "${auth_file}"
  if [[ "${status}" =~ ^2[0-9][0-9]$ ]]; then
    command cat "${response_file}"
    rm -f "${response_file}"
    return 0
  fi
  printf 'Distr API %s %s failed with HTTP %s\n' "${method}" "${endpoint}" "${status}" >&2
  if jq -e . "${response_file}" >/dev/null 2>&1; then
    jq -c 'walk(if type == "object" then with_entries(
      if (.key | test("(?i)(secret|password|token|value)")) then .value = "REDACTED" else . end
    ) else . end)' "${response_file}" >&2
  fi
  rm -f "${response_file}"
  return 1
}

guided_upsert_distr_secret() {
  local key="$1"
  local value="$2"
  local secrets secret_id body_file
  secrets="$(guided_distr_request GET /secrets)"
  secret_id="$(jq -r --arg key "${key}" '.[] | select(.key == $key) | .id' <<<"${secrets}" | head -n1)"
  guided_sensitive_temp distr-secret body_file
  if [[ -n "${secret_id}" ]]; then
    jq -n --arg value "${value}" '{value:$value}' >"${body_file}"
    guided_distr_request PUT "/secrets/${secret_id}?confirm=true" "${body_file}" >/dev/null
    guided_log "updated masked Hub secret ${key}"
  else
    jq -n --arg key "${key}" --arg value "${value}" \
      '{key:$key,value:$value}' >"${body_file}"
    guided_distr_request POST /secrets "${body_file}" >/dev/null
    guided_log "created masked Hub secret ${key}"
  fi
  rm -f "${body_file}"
}

guided_resolve_version() {
  local application_id="$1"
  local version_name="$2"
  local app version_id
  app="$(guided_distr_request GET "/applications/${application_id}")"
  version_id="$(jq -r --arg name "${version_name}" '
    [.versions[]? | select(.name == $name and .archivedAt == null)] | .[0].id // empty
  ' <<<"${app}")"
  [[ -n "${version_id}" ]] \
    || guided_die "application ${application_id} has no entitled, active version ${version_name}"
  printf '%s\n' "${version_id}"
}

guided_find_target() {
  local name="$1"
  guided_distr_request GET /deployment-targets \
    | jq -c --arg name "${name}" '.[] | select(.name == $name)' \
    | head -n1
}

guided_get_target() {
  local target_id="$1"
  guided_distr_request GET "/deployment-targets/${target_id}" \
    | jq -c 'if type == "array" then .[0] else . end'
}

guided_ensure_target() {
  local name="$1"
  local target_type="$2"
  local namespace="${3:-}"
  local target body_file
  target="$(guided_find_target "${name}")"
  if [[ -n "${target}" ]]; then
    [[ "$(jq -r .type <<<"${target}")" == "${target_type}" ]] \
      || guided_die "Distr target ${name} exists with the wrong type"
    if [[ "${target_type}" == "kubernetes" ]]; then
      [[ "$(jq -r '.namespace // ""' <<<"${target}")" == "${namespace}" ]] \
        || guided_die "Distr target ${name} exists with the wrong namespace"
    fi
    printf '%s\n' "${target}"
    return 0
  fi
  guided_sensitive_temp distr-target body_file
  if [[ "${target_type}" == "docker" ]]; then
    jq -n --arg name "${name}" '{
      name:$name,type:"docker",deployments:[],metricsEnabled:true,
      imageCleanupEnabled:true,deploymentLogsEnabled:true,autohealEnabled:true
    }' >"${body_file}"
  else
    jq -n --arg name "${name}" --arg namespace "${namespace}" '{
      name:$name,type:"kubernetes",namespace:$namespace,scope:"cluster",
      deployments:[],metricsEnabled:true,imageCleanupEnabled:false,
      deploymentLogsEnabled:true,autohealEnabled:false
    }' >"${body_file}"
  fi
  target="$(guided_distr_request POST /deployment-targets "${body_file}")"
  rm -f "${body_file}"
  guided_log "created Distr ${target_type} target ${name}"
  printf '%s\n' "${target}"
}

guided_find_deployment_id() {
  local target_json="$1"
  local application_id="$2"
  local release_name="${3:-}"
  jq -r --arg app "${application_id}" --arg release "${release_name}" '
    [.deployments[]? | select(
      ((.application.id // .applicationId) == $app)
      and ($release == "" or .releaseName == $release)
    )] | .[0].id // empty
  ' <<<"${target_json}"
}

guided_assert_dedicated_target() {
  local target_json="$1"
  local application_id="$2"
  local deployment_count matching_count
  deployment_count="$(jq '[.deployments[]?] | length' <<<"${target_json}")"
  matching_count="$(jq --arg app "${application_id}" '
    [.deployments[]? | select((.application.id // .applicationId) == $app)] | length
  ' <<<"${target_json}")"
  if [[ "${matching_count}" -gt 1 ]]; then
    guided_die "named Distr target contains duplicate deployments for application ${application_id}"
    return 1
  fi
  if [[ "${deployment_count}" -ne "${matching_count}" ]]; then
    guided_die "named Distr target is not dedicated to application ${application_id}"
    return 1
  fi
}

guided_put_deployment() {
  local target_id="$1"
  local application_version_id="$2"
  local deployment_id="$3"
  local release_name="$4"
  local data_file="$5"
  local deployment_type="$6"
  local encoded body_file
  encoded="$(guided_b64 <"${data_file}")"
  guided_sensitive_temp distr-deployment body_file
  if [[ "${deployment_type}" == "docker" ]]; then
    jq -n \
      --arg deploymentTargetId "${target_id}" \
      --arg applicationVersionId "${application_version_id}" \
      --arg deploymentId "${deployment_id}" \
      --arg envFileData "${encoded}" '
      {
        deploymentTargetId:$deploymentTargetId,
        applicationVersionId:$applicationVersionId,
        dockerType:"compose",envFileData:$envFileData,forceRestart:true
      } + (if $deploymentId != "" then {deploymentId:$deploymentId} else {} end)
    ' >"${body_file}"
  else
    jq -n \
      --arg deploymentTargetId "${target_id}" \
      --arg applicationVersionId "${application_version_id}" \
      --arg deploymentId "${deployment_id}" \
      --arg releaseName "${release_name}" \
      --arg valuesYaml "${encoded}" '
      {
        deploymentTargetId:$deploymentTargetId,
        applicationVersionId:$applicationVersionId,
        releaseName:$releaseName,valuesYaml:$valuesYaml,
        forceRestart:true,
        helmOptions:{
          timeout:"15m",waitStrategy:"watcher",
          rollbackOnFailure:true,cleanupOnFailure:true,forceConflicts:false
        }
      } + (if $deploymentId != "" then {deploymentId:$deploymentId} else {} end)
    ' >"${body_file}"
  fi
  guided_distr_request PUT /deployments "${body_file}" >/dev/null
  rm -f "${body_file}"
}

guided_request_target_access() {
  guided_distr_request POST "/deployment-targets/$1/access-request"
}

guided_write_infra_env() {
  local dry_run="$1"
  local dd_api_ref=""
  local dd_app_ref=""
  local dashboard_ref=""
  if [[ "${DATADOG_ENABLED}" == "true" ]]; then
    dd_api_ref="{{.Secrets.${HUB_DD_API_KEY_SECRET}}}"
    dd_app_ref="{{.Secrets.${HUB_DD_APP_KEY_SECRET}}}"
  fi
  if [[ "${DASHBOARD_BOOTSTRAP}" == "true" ]]; then
    dashboard_ref="{{.Secrets.${HUB_DASHBOARD_PASSWORD_SECRET}}}"
  fi
  {
    guided_dotenv_line DISTR_TOKEN "{{.Secrets.${HUB_DISTR_TOKEN_SECRET}}}"
    guided_dotenv_line DD_API_KEY "${dd_api_ref}"
    guided_dotenv_line DD_APP_KEY "${dd_app_ref}"
    guided_dotenv_line DASHBOARD_BOOTSTRAP_PASSWORD "${dashboard_ref}"
    guided_dotenv_line DASHBOARD_OIDC_CLIENT_SECRET ""
    guided_dotenv_line CLOUD gcp
    guided_dotenv_line DEPLOY_NAME "${INFRA_NAME}"
    guided_dotenv_line GATEWAY_DISTR_DEPLOYMENT_NAME "${GATEWAY_NAME}"
    guided_dotenv_line GCP_PROJECT "${PROJECT_ID}"
    guided_dotenv_line GCP_REGION us-east1
    guided_dotenv_line GCP_DNS_PROJECT_ID "${DNS_PROJECT_ID}"
    guided_dotenv_line DOMAIN_NAME "${DOMAIN_NAME}"
    guided_dotenv_line DNS_ZONE_NAME "${DNS_ZONE_NAME}"
    guided_dotenv_line TF_STATE_BUCKET "${PROJECT_ID}-subconscious-tfstate"
    guided_dotenv_line GKE_VERSION ""
    guided_dotenv_line GKE_RELEASE_CHANNEL REGULAR
    guided_dotenv_line GCP_NODE_MACHINE_TYPE n4a-standard-4
    guided_dotenv_line NODE_DESIRED_SIZE 2
    guided_dotenv_line NODE_MIN_SIZE 2
    guided_dotenv_line NODE_MAX_SIZE 4
    guided_dotenv_line VPC_CIDR "${PLATFORM_VPC_CIDR}"
    guided_dotenv_line CLUSTER_ENDPOINT_PUBLIC_ACCESS false
    guided_dotenv_line CLUSTER_ENDPOINT_PUBLIC_ACCESS_CIDRS ""
    guided_dotenv_line CLOUDSQL_TIER db-custom-2-7680
    guided_dotenv_line CLOUDSQL_STORAGE_GB 50
    guided_dotenv_line MEMORYSTORE_MEMORY_GB 5
    guided_dotenv_line GCP_DELETION_PROTECTION true
    guided_dotenv_line GCP_EXTERNAL_DNS_ENABLED false
    guided_dotenv_line DATADOG_ENABLED "${DATADOG_ENABLED}"
    guided_dotenv_line DATADOG_SITE "${DATADOG_SITE}"
    guided_dotenv_line DATADOG_ENV "${PROJECT_ID}"
    guided_dotenv_line DATADOG_GCP_CLOUD_METRICS_ENABLED "${DATADOG_ENABLED}"
    guided_dotenv_line DATADOG_POSTGRES_DBM_PREREQUISITES_ENABLED false
    guided_dotenv_line DATADOG_POSTGRES_DBM_ENABLED false
    guided_dotenv_line DATADOG_POSTGRES_DBM_BOOTSTRAP_REVISION 1
    guided_dotenv_line DATADOG_DATABASE_MONITORS_ENABLED false
    guided_dotenv_line DATADOG_DATABASE_MONITORS_DRAFT true
    guided_dotenv_line DATADOG_MONITORS_DRAFT true
    guided_dotenv_line DATADOG_INCLUDE_ROUTER_MONITORS true
    guided_dotenv_line DATADOG_INCLUDE_ADAPTER_MONITORS true
    guided_dotenv_line DATADOG_SLOS_ENABLED false
    guided_dotenv_line DATADOG_MONITOR_NOTIFICATION ""
    guided_dotenv_line GATEWAY_AUTO_DEPLOY false
    guided_dotenv_line GATEWAY_CHART_VERSION "${GATEWAY_VERSION}"
    guided_dotenv_line DISTR_GATEWAY_APPLICATION_ID "${GATEWAY_APPLICATION_ID}"
    guided_dotenv_line DISTR_GATEWAY_APPLICATION_VERSION_ID ""
    guided_dotenv_line GATEWAY_ROUTE_ALLOWED_HOST_SUFFIXES "${ROUTE_SUFFIXES}"
    guided_dotenv_line DASHBOARD_BOOTSTRAP_USERNAME "${DASHBOARD_USERNAME}"
    guided_dotenv_line DASHBOARD_BOOTSTRAP_ORG_NAME "${DASHBOARD_ORG_NAME}"
    guided_dotenv_line DASHBOARD_BOOTSTRAP_FULL_NAME "${DASHBOARD_FULL_NAME}"
    guided_dotenv_line DASHBOARD_OIDC_ENABLED false
    guided_dotenv_line DASHBOARD_OIDC_PROVIDER generic
    guided_dotenv_line DASHBOARD_OIDC_ISSUER_URL ""
    guided_dotenv_line DASHBOARD_OIDC_CLIENT_ID ""
    guided_dotenv_line DASHBOARD_OIDC_REDIRECT_URI ""
    guided_dotenv_line DASHBOARD_OIDC_SCOPES openid,email,profile
    guided_dotenv_line DISTR_DRY_RUN "${dry_run}"
  } >"${INFRA_ENV_FILE}"
  chmod 600 "${INFRA_ENV_FILE}"
}

guided_prepare_hub_secrets() {
  guided_upsert_distr_secret "${HUB_DISTR_TOKEN_SECRET}" "${INSTALL_DISTR_TOKEN}"
  if [[ "${DATADOG_ENABLED}" == "true" ]]; then
    local dd_api_key=""
    local dd_app_key=""
    guided_prompt_secret "Datadog API key" dd_api_key
    guided_prompt_secret "Datadog application key" dd_app_key
    [[ "${dd_api_key}" =~ ^[A-Za-z0-9]+$ && "${dd_app_key}" =~ ^[A-Za-z0-9]+$ ]] \
      || guided_die "Datadog keys must contain only letters and digits"
    guided_upsert_distr_secret "${HUB_DD_API_KEY_SECRET}" "${dd_api_key}"
    guided_upsert_distr_secret "${HUB_DD_APP_KEY_SECRET}" "${dd_app_key}"
    unset dd_api_key dd_app_key
  fi
  if [[ "${DASHBOARD_BOOTSTRAP}" == "true" ]]; then
    local dashboard_password=""
    guided_prompt_secret "Initial dashboard administrator password" dashboard_password
    [[ "${#dashboard_password}" -ge 12 ]] \
      || guided_die "dashboard password must contain at least 12 characters"
    [[ "${dashboard_password}" != *$'\n'* \
      && "${dashboard_password}" != *$'\r'* \
      && "${dashboard_password}" != *"'"* ]] \
      || guided_die "dashboard password cannot contain a newline or apostrophe"
    guided_upsert_distr_secret "${HUB_DASHBOARD_PASSWORD_SECRET}" "${dashboard_password}"
    unset dashboard_password
  fi
}

guided_connect_infra_target() {
  local target_json="$1"
  local target_id access connect_url
  if [[ "$(guided_state_get infraConnected)" == "true" ]]; then
    return 0
  fi
  target_id="$(jq -r .id <<<"${target_json}")"
  access="$(guided_request_target_access "${target_id}")"
  connect_url="$(jq -er '.connectUrl' <<<"${access}")"
  printf '%s\n' "${connect_url}" | "${SCRIPT_DIR}/run-agent.sh"
  guided_state_set infraConnected "true"
}

guided_ensure_infra_deployment() {
  local dry_run="$1"
  local target target_id deployment_id version_id
  target="$(guided_ensure_target "${INFRA_NAME}" docker)"
  target_id="$(jq -er .id <<<"${target}")"
  version_id="$(guided_state_get infraVersionId)"
  if [[ -z "${version_id}" ]]; then
    version_id="$(guided_resolve_version "${INFRA_APPLICATION_ID}" "${INFRA_VERSION}")"
    guided_state_set infraVersionId "${version_id}"
  fi
  target="$(guided_get_target "${target_id}")"
  guided_assert_dedicated_target "${target}" "${INFRA_APPLICATION_ID}"
  deployment_id="$(guided_find_deployment_id "${target}" "${INFRA_APPLICATION_ID}")"
  guided_write_infra_env "${dry_run}"
  guided_put_deployment "${target_id}" "${version_id}" "${deployment_id}" "" \
    "${INFRA_ENV_FILE}" docker
  target="$(guided_get_target "${target_id}")"
  deployment_id="$(guided_find_deployment_id "${target}" "${INFRA_APPLICATION_ID}")"
  [[ -n "${deployment_id}" ]] || guided_die "could not resolve the infra deployment after update"
  guided_state_set infraTargetId "${target_id}"
  guided_state_set infraDeploymentId "${deployment_id}"
  guided_connect_infra_target "${target}"
}

guided_runner_logs() {
  bootstrap_ssh --command='sudo bash -c '\''container_id="$(docker ps -aq --filter label=com.docker.compose.service=runner | head -n1)"; test -n "${container_id}"; docker logs "${container_id}" 2>&1'\'''
}

guided_runner_state() {
  bootstrap_ssh --command='sudo bash -c '\''container_id="$(docker ps -aq --filter label=com.docker.compose.service=runner | head -n1)"; test -n "${container_id}"; docker inspect -f "{{.State.Status}} {{.State.ExitCode}}" "${container_id}"'\'''
}

guided_infra_revision_matches() {
  local dry_run="$1"
  local target_id version_id target deployment_id actual_version actual_env expected_env
  target_id="$(guided_state_get infraTargetId)"
  version_id="$(guided_state_get infraVersionId)"
  [[ -n "${target_id}" && -n "${version_id}" ]] || return 1
  guided_write_infra_env "${dry_run}"
  expected_env="$(guided_b64 <"${INFRA_ENV_FILE}")"
  target="$(guided_get_target "${target_id}")"
  deployment_id="$(guided_find_deployment_id "${target}" "${INFRA_APPLICATION_ID}")"
  [[ -n "${deployment_id}" ]] || return 1
  actual_version="$(jq -r --arg id "${deployment_id}" '
    [.deployments[]? | select(.id == $id)] | .[0].applicationVersionId // empty
  ' <<<"${target}")"
  actual_env="$(jq -r --arg id "${deployment_id}" '
    [.deployments[]? | select(.id == $id)] | .[0].envFileData // empty
  ' <<<"${target}")"
  [[ "${actual_version}" == "${version_id}" && "${actual_env}" == "${expected_env}" ]]
}

guided_runner_revision_failed() {
  local container_state target target_id deployment_id status
  container_state="$(guided_runner_state 2>/dev/null || true)"
  [[ "${container_state}" == exited* ]] && return 0
  target_id="$(guided_state_get infraTargetId)"
  deployment_id="$(guided_state_get infraDeploymentId)"
  [[ -n "${target_id}" && -n "${deployment_id}" ]] || return 1
  target="$(guided_get_target "${target_id}")"
  status="$(jq -r --arg id "${deployment_id}" '
    [.deployments[]? | select(.id == $id)] | .[0].latestStatus.type // empty
  ' <<<"${target}")"
  [[ "${status}" == "error" ]]
}

guided_gke_exists() {
  gcloud container clusters describe "${INFRA_NAME}-gke" \
    --project="${PROJECT_ID}" \
    --location=us-east1 \
    --format='value(name)' \
    --quiet >/dev/null 2>&1
}

guided_wait_runner() {
  local marker="$1"
  local deadline=$((SECONDS + GUIDED_WAIT_SECONDS))
  local logs=""
  local container_state=""
  while (( SECONDS < deadline )); do
    logs="$(guided_runner_logs 2>/dev/null || true)"
    if grep -Fq "${marker}" <<<"${logs}"; then
      printf '%s\n' "${logs}"
      return 0
    fi
    container_state="$(guided_runner_state 2>/dev/null || true)"
    if [[ "${container_state}" =~ ^exited[[:space:]]+([1-9][0-9]*)$ ]]; then
      printf '%s\n' "${logs}" >&2
      guided_die "infra runner exited before reaching: ${marker}"
      return 1
    fi
    guided_log "waiting for runner: ${marker}"
    sleep "${GUIDED_POLL_SECONDS}"
  done
  printf '%s\n' "${logs}" >&2
  guided_die "timed out waiting for runner: ${marker}"
}

guided_foundation_plan() {
  guided_ensure_infra_deployment 1
  local logs checksum
  logs="$(guided_wait_runner 'dry-run plan saved; review required before apply')"
  printf '\n%s\n' "${logs}" >&2
  checksum="$(sed -nE 's/.*saved exact foundation plan for the next approved apply \(([0-9a-f]{64})\).*/\1/p' <<<"${logs}" | tail -n1)"
  [[ -n "${checksum}" ]] || guided_die "foundation plan checksum was not found in runner logs"
  guided_state_set foundationPlanChecksum "${checksum}"
  guided_state_set stage "foundation_planned"
}

guided_apply_foundation() {
  guided_approve 2 "apply the exact reviewed cloud-foundation plan ($(guided_state_get foundationPlanChecksum))"
  guided_state_set stage "foundation_applying"
  guided_finish_foundation_apply
}

guided_finish_foundation_apply() {
  local logs
  logs="$(guided_runner_logs 2>/dev/null || true)"
  if grep -Fq 'full platform apply intentionally paused' <<<"${logs}"; then
    guided_state_set stage "foundation_applied"
    return 0
  fi
  if guided_runner_revision_failed; then
    if guided_gke_exists; then
      guided_log "GKE exists after the interrupted foundation execution; the complete plan will reconcile remaining work"
      guided_state_set stage "foundation_applied"
      return 0
    fi
    guided_state_set stage "foundation_replan"
    guided_die "cloud-foundation execution failed; rerun to generate and approve a fresh remaining-work plan"
    return 1
  fi
  if ! guided_infra_revision_matches 0; then
    guided_ensure_infra_deployment 0
  fi
  if ! guided_wait_runner 'full platform apply intentionally paused' >&2; then
    if guided_gke_exists; then
      guided_log "GKE exists after the interrupted foundation execution; the complete plan will reconcile remaining work"
      guided_state_set stage "foundation_applied"
      return 0
    fi
    guided_state_set stage "foundation_replan"
    return 1
  fi
  guided_state_set stage "foundation_applied"
}

guided_platform_plan() {
  guided_ensure_infra_deployment 1
  local logs checksum
  logs="$(guided_wait_runner 'dry-run plan saved; review required before apply')"
  printf '\n%s\n' "${logs}" >&2
  checksum="$(sed -nE 's/.*saved exact complete plan for the next approved apply \(([0-9a-f]{64})\).*/\1/p' <<<"${logs}" | tail -n1)"
  [[ -n "${checksum}" ]] || guided_die "complete plan checksum was not found in runner logs"
  guided_state_set platformPlanChecksum "${checksum}"
  guided_state_set stage "platform_planned"
}

guided_apply_platform() {
  guided_approve 3 "apply the exact reviewed complete platform plan ($(guided_state_get platformPlanChecksum))"
  guided_state_set stage "platform_applying"
  guided_finish_platform_apply
}

guided_finish_platform_apply() {
  local logs
  logs="$(guided_runner_logs 2>/dev/null || true)"
  if grep -Fq 'platform apply complete; idling for Distr Docker agent health' <<<"${logs}"; then
    guided_state_set stage "platform_applied"
    return 0
  fi
  if guided_runner_revision_failed; then
    guided_state_set stage "platform_replan"
    guided_die "complete-platform execution failed; rerun to generate and approve a fresh remaining-work plan"
    return 1
  fi
  if ! guided_infra_revision_matches 0; then
    guided_ensure_infra_deployment 0
  fi
  if ! guided_wait_runner 'platform apply complete; idling for Distr Docker agent health' >&2; then
    guided_state_set stage "platform_replan"
    return 1
  fi
  guided_state_set stage "platform_applied"
}

guided_fetch_gateway_values() {
  {
    printf 'GATEWAY_NAME=%q\n' "${GATEWAY_NAME}"
    cat <<'REMOTE'
set -euo pipefail
container_id="$(docker ps -q --filter label=com.docker.compose.service=runner | head -n1)"
test -n "${container_id}"
docker exec "${container_id}" cat "/app/.generated/${GATEWAY_NAME}-gateway-overrides.yaml"
REMOTE
  } | bootstrap_ssh --command='sudo bash -s' >"${GATEWAY_VALUES_FILE}"
  chmod 600 "${GATEWAY_VALUES_FILE}"
  [[ -s "${GATEWAY_VALUES_FILE}" ]] || guided_die "runner did not produce gateway Helm values"
  if grep -Eq '(password|token|secret):[[:space:]]*[^[:space:]]' "${GATEWAY_VALUES_FILE}"; then
    guided_die "generated gateway values appear to contain inline secret material"
  fi
}

guided_connect_gateway_target() {
  local target_id="$1"
  local access connect_command
  if [[ "$(guided_state_get gatewayConnected)" == "true" ]]; then
    return 0
  fi
  access="$(guided_request_target_access "${target_id}")"
  connect_command="$(jq -er '.connectCommand' <<<"${access}")"
  printf '%s\n' "${connect_command}" \
    | "${SCRIPT_DIR}/connect-k8s-agent.sh" "${INFRA_NAME}"
  guided_state_set gatewayConnected "true"
}

guided_wait_gateway() {
  local target_id="$1"
  local deployment_id="$2"
  local deadline=$((SECONDS + GUIDED_WAIT_SECONDS))
  local target status message
  while (( SECONDS < deadline )); do
    target="$(guided_get_target "${target_id}")"
    status="$(jq -r --arg id "${deployment_id}" '
      [.deployments[]? | select(.id == $id)] | .[0].latestStatus.type // empty
    ' <<<"${target}")"
    message="$(jq -r --arg id "${deployment_id}" '
      [.deployments[]? | select(.id == $id)] | .[0].latestStatus.message // empty
    ' <<<"${target}")"
    case "${status}" in
      healthy)
        guided_log "gateway deployment is healthy"
        return 0
        ;;
      error)
        guided_die "gateway deployment failed: ${message:-no status message}"
        return 1
        ;;
    esac
    guided_log "waiting for gateway deployment (${status:-no status yet})"
    sleep "${GUIDED_POLL_SECONDS}"
  done
  guided_die "timed out waiting for the gateway deployment"
}

guided_deploy_gateway() {
  guided_fetch_gateway_values
  local gateway_version_id values_checksum
  gateway_version_id="$(guided_state_get gatewayVersionId)"
  if [[ -z "${gateway_version_id}" ]]; then
    gateway_version_id="$(guided_resolve_version "${GATEWAY_APPLICATION_ID}" "${GATEWAY_VERSION}")"
    guided_state_set gatewayVersionId "${gateway_version_id}"
  fi
  printf '\nPinned gateway version: %s (%s)\n' "${GATEWAY_VERSION}" "${gateway_version_id}" >&2
  printf 'Generated Helm values:\n\n' >&2
  command cat "${GATEWAY_VALUES_FILE}" >&2
  guided_approve 4 "create/connect the Kubernetes target and deploy these exact Helm values"
  values_checksum="$(guided_sha256 <"${GATEWAY_VALUES_FILE}")"
  guided_state_set gatewayValuesChecksum "${values_checksum}"
  guided_state_set stage "gateway_deploying"
  guided_finish_gateway_deploy
}

guided_finish_gateway_deploy() {
  local gateway_version_id expected_checksum actual_checksum
  local target target_id deployment_id current_version current_values expected_values status
  gateway_version_id="$(guided_state_get gatewayVersionId)"
  expected_checksum="$(guided_state_get gatewayValuesChecksum)"
  [[ -n "${gateway_version_id}" && -n "${expected_checksum}" ]] \
    || guided_die "approved gateway version or values checksum is missing"
  guided_fetch_gateway_values
  actual_checksum="$(guided_sha256 <"${GATEWAY_VALUES_FILE}")"
  if [[ "${actual_checksum}" != "${expected_checksum}" ]]; then
    guided_state_set stage "platform_applied"
    guided_die "generated Helm values changed after approval; rerun to review Gate 4 again"
    return 1
  fi

  target="$(guided_ensure_target "${GATEWAY_NAME}" kubernetes "${GATEWAY_NAME}")"
  target_id="$(jq -er .id <<<"${target}")"
  target="$(guided_get_target "${target_id}")"
  guided_assert_dedicated_target "${target}" "${GATEWAY_APPLICATION_ID}"
  deployment_id="$(guided_find_deployment_id "${target}" "${GATEWAY_APPLICATION_ID}" "${GATEWAY_NAME}")"
  expected_values="$(guided_b64 <"${GATEWAY_VALUES_FILE}")"
  current_version="$(jq -r --arg id "${deployment_id}" '
    [.deployments[]? | select(.id == $id)] | .[0].applicationVersionId // empty
  ' <<<"${target}")"
  current_values="$(jq -r --arg id "${deployment_id}" '
    [.deployments[]? | select(.id == $id)] | .[0].valuesYaml // empty
  ' <<<"${target}")"
  status="$(jq -r --arg id "${deployment_id}" '
    [.deployments[]? | select(.id == $id)] | .[0].latestStatus.type // empty
  ' <<<"${target}")"
  if [[ -z "${deployment_id}" \
    || "${current_version}" != "${gateway_version_id}" \
    || "${current_values}" != "${expected_values}" \
    || "${status}" == "error" ]]; then
    guided_put_deployment "${target_id}" "${gateway_version_id}" "${deployment_id}" \
      "${GATEWAY_NAME}" "${GATEWAY_VALUES_FILE}" kubernetes
  fi
  target="$(guided_get_target "${target_id}")"
  deployment_id="$(guided_find_deployment_id "${target}" "${GATEWAY_APPLICATION_ID}" "${GATEWAY_NAME}")"
  [[ -n "${deployment_id}" ]] || guided_die "could not resolve gateway deployment after update"
  guided_state_set gatewayTargetId "${target_id}"
  guided_state_set gatewayDeploymentId "${deployment_id}"
  guided_connect_gateway_target "${target_id}"
  guided_wait_gateway "${target_id}" "${deployment_id}"
  guided_state_set stage "gateway_deployed"
}

guided_platform_output() {
  local output_name="$1"
  {
    printf 'OUTPUT_NAME=%q\n' "${output_name}"
    cat <<'REMOTE'
set -euo pipefail
container_id="$(docker ps -q --filter label=com.docker.compose.service=runner | head -n1)"
test -n "${container_id}"
docker exec "${container_id}" terraform -chdir=/app/platforms/gcp output -raw "${OUTPUT_NAME}"
REMOTE
  } | bootstrap_ssh --command='sudo bash -s'
}

guided_acceptance() {
  local cloudsql_instance redis_instance deadline smoke_output
  cloudsql_instance="$(guided_platform_output cloudsql_instance_name)"
  redis_instance="$(guided_platform_output memorystore_instance_name)"
  deadline=$((SECONDS + GUIDED_WAIT_SECONDS))
  while (( SECONDS < deadline )); do
    if smoke_output="$(
      DATADOG_ENABLED="${DATADOG_ENABLED}" "${SCRIPT_DIR}/smoke-checks.sh" \
        "${INFRA_NAME}" "${GATEWAY_NAME}" "${DOMAIN_NAME}" \
        "${cloudsql_instance}" "${redis_instance}" 2>&1
    )"; then
      printf '%s\n' "${smoke_output}" >&2
      break
    fi
    printf '%s\n' "${smoke_output}" >&2
    guided_log "acceptance is not ready; retrying in ${GUIDED_ACCEPTANCE_POLL_SECONDS}s"
    sleep "${GUIDED_ACCEPTANCE_POLL_SECONDS}"
  done
  [[ "${smoke_output}" == *"[smoke] OK"* ]] \
    || guided_die "timed out waiting for production acceptance checks"
  guided_approve 5 "accept the passing production smoke checks and complete installation"
  guided_state_set stage "complete"
  guided_log "production installation complete: https://${DOMAIN_NAME}"
}

guided_main() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --config)
        [[ $# -ge 2 ]] || {
          guided_usage
          return 2
        }
        CONFIG_FILE="$2"
        shift 2
        ;;
      -h|--help)
        guided_usage
        return 0
        ;;
      *)
        guided_usage
        return 2
        ;;
    esac
  done
  [[ -n "${CONFIG_FILE}" && -f "${CONFIG_FILE}" ]] \
    || guided_die "--config must name an existing JSON file"
  CONFIG_FILE="$(cd "$(dirname "${CONFIG_FILE}")" && pwd)/$(basename "${CONFIG_FILE}")"

  for tool in jq terraform curl python3 base64; do
    guided_need "${tool}"
  done
  if ! command -v sha256sum >/dev/null 2>&1 \
    && ! command -v shasum >/dev/null 2>&1; then
    guided_die "sha256sum or shasum is required"
  fi
  for wait_value in \
    "${GUIDED_WAIT_SECONDS}" \
    "${GUIDED_POLL_SECONDS}" \
    "${GUIDED_ACCEPTANCE_POLL_SECONDS}"; do
    [[ "${wait_value}" =~ ^[1-9][0-9]*$ ]] \
      || guided_die "guided installer wait settings must be positive integers"
  done
  guided_validate_config
  guided_initialize_state
  guided_write_bootstrap_vars
  guided_write_infra_env 1

  local stage
  stage="$(guided_state_get stage)"
  if [[ "${stage}" == "complete" ]]; then
    guided_log "already complete: https://${DOMAIN_NAME}"
    return 0
  fi
  guided_ensure_google_auth
  if [[ "${stage}" == "new" ]]; then
    guided_gate_one
    stage="$(guided_state_get stage)"
  fi
  if [[ "${stage}" == "bootstrap_applying" ]]; then
    guided_finish_bootstrap_apply
    stage="$(guided_state_get stage)"
  fi
  if [[ "${stage}" == "bootstrap_applied" ]]; then
    guided_finish_bootstrap
    stage="$(guided_state_get stage)"
  fi

  if [[ "${stage}" != "complete" ]]; then
    guided_ensure_distr_token
  fi
  if [[ "${stage}" == "bootstrap_ready" ]]; then
    guided_prepare_hub_secrets
    guided_foundation_plan
    stage="$(guided_state_get stage)"
  fi
  if [[ "${stage}" == "foundation_replan" ]]; then
    guided_foundation_plan
    stage="$(guided_state_get stage)"
  fi
  if [[ "${stage}" == "foundation_planned" ]]; then
    guided_apply_foundation
    stage="$(guided_state_get stage)"
  fi
  if [[ "${stage}" == "foundation_applying" ]]; then
    guided_finish_foundation_apply
    stage="$(guided_state_get stage)"
  fi
  if [[ "${stage}" == "foundation_applied" ]]; then
    guided_platform_plan
    stage="$(guided_state_get stage)"
  fi
  if [[ "${stage}" == "platform_replan" ]]; then
    guided_platform_plan
    stage="$(guided_state_get stage)"
  fi
  if [[ "${stage}" == "platform_planned" ]]; then
    guided_apply_platform
    stage="$(guided_state_get stage)"
  fi
  if [[ "${stage}" == "platform_applying" ]]; then
    guided_finish_platform_apply
    stage="$(guided_state_get stage)"
  fi
  if [[ "${stage}" == "platform_applied" ]]; then
    guided_deploy_gateway
    stage="$(guided_state_get stage)"
  fi
  if [[ "${stage}" == "gateway_deploying" ]]; then
    guided_finish_gateway_deploy
    stage="$(guided_state_get stage)"
  fi
  if [[ "${stage}" == "gateway_deployed" ]]; then
    guided_acceptance
    stage="$(guided_state_get stage)"
  fi
  [[ "${stage}" == "complete" ]] \
    || guided_die "unknown or incomplete installer stage: ${stage}"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  guided_main "$@"
fi
