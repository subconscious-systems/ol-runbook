#!/usr/bin/env bash
# Shared helpers for the Azure one-command gateway bootstrap.
# shellcheck shell=bash

AZGW_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AZGW_BOOTSTRAP_DIR="$(cd "${AZGW_SCRIPT_DIR}/.." && pwd)"
AZGW_AZURE_DIR="$(cd "${AZGW_BOOTSTRAP_DIR}/.." && pwd)"
AZGW_GENERATED_DIR="${AZGW_AZURE_DIR}/.generated"

: "${DISTR_API_BASE:=https://app.distr.sh/api/v1}"
: "${DISTR_DRY_RUN:=0}"

azgw_log() {
  printf '[azure-setup] %s\n' "$*" >&2
}

azgw_die() {
  azgw_log "ERROR: $*"
  exit 1
}

azgw_need() {
  command -v "$1" >/dev/null 2>&1 || azgw_die "$1 is required"
}

azgw_json_b64() {
  if base64 --help 2>&1 | grep -q -- '-w'; then
    base64 -w 0
  else
    base64 | tr -d '\n'
  fi
}

azgw_slug() {
  printf '%s' "$1" \
    | tr '[:upper:]' '[:lower:]' \
    | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//; s/-+/-/g'
}

azgw_dns1123() {
  [[ "${1:-}" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]]
}

azgw_hash8() {
  printf '%s' "$1" \
    | openssl dgst -sha256 -binary \
    | od -An -tx1 \
    | tr -d ' \n' \
    | cut -c1-8
}

azgw_secret_key() {
  printf '%s' "$1" \
    | tr '[:lower:]-' '[:upper:]_' \
    | sed -E 's/[^A-Z0-9_]+/_/g'
}

azgw_public_suffix() {
  python3 - "$1" <<'PY'
import sys
host = sys.argv[1].strip().strip(".").lower()
parts = host.split(".")
if len(parts) >= 2:
    print(".".join(parts[-2:]))
else:
    print(host)
PY
}

azgw_prompt() {
  local var_name="$1"
  local prompt="$2"
  local current="${!var_name:-}"
  if [[ -n "${current}" ]]; then
    return 0
  fi
  [[ -t 0 ]] || azgw_die "${var_name} is required in non-interactive mode"
  printf '%s: ' "${prompt}" >&2
  read -r current
  printf -v "${var_name}" '%s' "${current}"
}

azgw_prompt_secret() {
  local var_name="$1"
  local prompt="$2"
  local current="${!var_name:-}"
  if [[ -n "${current}" ]]; then
    return 0
  fi
  [[ -t 0 ]] || azgw_die "${var_name} is required in non-interactive mode"
  printf '%s: ' "${prompt}" >&2
  stty -echo
  read -r current
  stty echo
  printf '\n' >&2
  printf -v "${var_name}" '%s' "${current}"
}

azgw_ensure_azure_session() {
  if ! az account show --output none --only-show-errors >/dev/null 2>&1; then
    azgw_log "no active Azure CLI session; opening az login"
    az login --only-show-errors >/dev/null
  fi
  AZURE_ACCOUNT_JSON="$(az account show --output json --only-show-errors)" \
    || azgw_die "cannot inspect the active Azure account"
  AZURE_SUBSCRIPTION_ID="$(jq -er '.id' <<<"${AZURE_ACCOUNT_JSON}")"
  AZURE_TENANT_ID="$(jq -er '.tenantId' <<<"${AZURE_ACCOUNT_JSON}")"
  AZURE_ACCOUNT_NAME="$(jq -r '.user.name // ""' <<<"${AZURE_ACCOUNT_JSON}")"
  az account set --subscription "${AZURE_SUBSCRIPTION_ID}" --only-show-errors
}

azgw_register_providers() {
  local provider
  if [[ "${DISTR_DRY_RUN}" == "1" ]]; then
    azgw_log "DRY_RUN would register required Azure resource providers"
    return 0
  fi
  for provider in \
    Microsoft.Authorization \
    Microsoft.Compute \
    Microsoft.ContainerService \
    Microsoft.DBforPostgreSQL \
    Microsoft.KeyVault \
    Microsoft.ManagedIdentity \
    Microsoft.Network \
    Microsoft.Storage \
    Microsoft.Cache; do
    azgw_log "registering ${provider} if needed"
    az provider register --namespace "${provider}" --only-show-errors >/dev/null
  done
}

azgw_resolve_dns_zone() {
  local hostname="$1"
  local explicit="${2:-}"
  local zone_json
  if [[ -n "${explicit}" ]]; then
    zone_json="$(az resource show --ids "${explicit}" --output json --only-show-errors)" \
      || azgw_die "could not inspect --dns-zone ${explicit}"
    DNS_ZONE_ID="$(jq -er '.id' <<<"${zone_json}")"
    DNS_ZONE_NAME="$(jq -er '.name' <<<"${zone_json}")"
    DNS_ZONE_RESOURCE_GROUP="$(sed -E 's#^/subscriptions/[^/]+/resourceGroups/([^/]+)/.*#\1#' <<<"${DNS_ZONE_ID}")"
    return 0
  fi

  zone_json="$(az network dns zone list --output json --only-show-errors)" \
    || azgw_die "cannot list Azure DNS zones"
  read -r DNS_ZONE_ID DNS_ZONE_NAME DNS_ZONE_RESOURCE_GROUP < <(
    python3 - "${hostname}" "${zone_json}" <<'PY'
import json
import sys

host = sys.argv[1].strip().strip(".").lower()
zones = json.loads(sys.argv[2])
matches = []
for zone in zones:
    name = (zone.get("name") or "").strip(".").lower()
    if host == name or host.endswith("." + name):
        matches.append((len(name), zone.get("id", ""), zone.get("name", ""), zone.get("resourceGroup", "")))
matches.sort(reverse=True)
if not matches:
    raise SystemExit("NO_MATCH")
best_len = matches[0][0]
best = [m for m in matches if m[0] == best_len]
if len(best) > 1:
    raise SystemExit("AMBIGUOUS")
_, zone_id, name, rg = best[0]
print(zone_id, name, rg)
PY
  ) || {
    azgw_log "could not pick a unique Azure DNS zone for ${hostname}"
    azgw_log "rerun with --dns-zone /subscriptions/.../resourceGroups/.../providers/Microsoft.Network/dnszones/<zone>"
    exit 1
  }
}

azgw_select_vnet_cidr() {
  local vnets_json
  if [[ -n "${VNET_CIDR:-}" ]]; then
    return 0
  fi
  vnets_json="$(az network vnet list --output json --only-show-errors)" \
    || azgw_die "cannot list Azure VNets for CIDR selection"
  VNET_CIDR="$(
    python3 - "${vnets_json}" <<'PY'
import ipaddress
import json
import sys

used = []
for vnet in json.loads(sys.argv[1]):
    for prefix in (vnet.get("addressSpace") or {}).get("addressPrefixes") or []:
        try:
            used.append(ipaddress.ip_network(prefix, strict=False))
        except ValueError:
            pass
candidates = [
    ipaddress.ip_network(f"10.{i}.0.0/16")
    for i in range(70, 100)
] + [
    ipaddress.ip_network(f"172.{i}.0.0/16")
    for i in range(20, 32)
]
for candidate in candidates:
    if not any(candidate.overlaps(existing) for existing in used):
        print(candidate)
        break
else:
    raise SystemExit("no unused private /16 candidate found")
PY
  )"
}

distr_api_request() {
  local method="$1"
  local path="$2"
  local body_file="${3:-}"
  local url="${DISTR_API_BASE}${path}"
  local response_file status

  if [[ "${DISTR_DRY_RUN}" == "1" ]]; then
    printf '{"dry_run":true,"method":"%s","path":"%s"}\n' "${method}" "${path}"
    return 0
  fi

  response_file="$(mktemp)"
  chmod 600 "${response_file}"
  local curl_args=(
    --silent
    --show-error
    --request "${method}"
    --header "Accept: application/json"
    --header "Authorization: AccessToken ${DISTR_TOKEN}"
    --output "${response_file}"
    --write-out "%{http_code}"
  )
  if [[ -n "${body_file}" ]]; then
    curl_args+=(--header "Content-Type: application/json" --data-binary "@${body_file}")
  fi

  status="$(curl "${curl_args[@]}" "${url}")" || status="000"
  if [[ "${status}" =~ ^2[0-9][0-9]$ ]]; then
    command cat "${response_file}"
    rm -f "${response_file}"
    return 0
  fi
  printf 'Distr API %s %s failed with HTTP %s\n' "${method}" "${path}" "${status}" >&2
  if [[ -s "${response_file}" ]]; then
    jq -c 'walk(if type == "object" then with_entries(if (.key|test("(?i)(value|secret|token|password)")) then .value="REDACTED" else . end) else . end)' "${response_file}" >&2 \
      || printf '<non-JSON response redacted>\n' >&2
  fi
  rm -f "${response_file}"
  return 1
}

distr_upsert_secret() {
  local key="$1"
  local value="$2"
  local secrets secret_id body
  if [[ "${DISTR_DRY_RUN}" == "1" ]]; then
    azgw_log "DRY_RUN would upsert Hub Secret ${key}"
    return 0
  fi
  secrets="$(distr_api_request GET "/secrets")"
  secret_id="$(jq -r --arg key "${key}" '.[] | select(.key == $key) | .id' <<<"${secrets}" | head -n 1)"
  body="$(mktemp)"
  chmod 600 "${body}"
  if [[ -n "${secret_id}" ]]; then
    jq -n --arg value "${value}" '{value: $value}' >"${body}"
    distr_api_request PUT "/secrets/${secret_id}?confirm=true" "${body}" >/dev/null
  else
    if [[ -n "${DISTR_CUSTOMER_ORG_ID:-}" ]]; then
      jq -n --arg key "${key}" --arg value "${value}" --arg customerOrganizationId "${DISTR_CUSTOMER_ORG_ID}" \
        '{key: $key, value: $value, customerOrganizationId: $customerOrganizationId}' >"${body}"
    else
      jq -n --arg key "${key}" --arg value "${value}" '{key: $key, value: $value}' >"${body}"
    fi
    distr_api_request POST "/secrets" "${body}" >/dev/null
  fi
  rm -f "${body}"
}

distr_application_latest_version() {
  local app_id="$1"
  if [[ "${DISTR_DRY_RUN}" == "1" ]]; then
    printf '00000000-0000-0000-0000-000000000000\t0.0.0-dry-run\n'
    return 0
  fi
  distr_api_request GET "/applications/${app_id}" \
    | jq -r '
      [.versions // [] | .[] | select(.archivedAt == null)]
      | sort_by(.createdAt)
      | reverse
      | .[0]
      | select(. != null)
      | "\(.id)\t\(.name)"
    '
}

distr_find_target_by_name() {
  local name="$1"
  if [[ "${DISTR_DRY_RUN}" == "1" ]]; then
    return 0
  fi
  distr_api_request GET "/deployment-targets" \
    | jq -c --arg name "${name}" '.[] | select(.name == $name)'
}

distr_create_docker_target() {
  local name="$1"
  local body
  body="$(mktemp)"
  chmod 600 "${body}"
  if [[ -n "${DISTR_CUSTOMER_ORG_ID:-}" ]]; then
    jq -n --arg name "${name}" --arg customer_id "${DISTR_CUSTOMER_ORG_ID}" \
      '{name:$name,type:"docker",deployments:[],metricsEnabled:false,imageCleanupEnabled:false,deploymentLogsEnabled:true,autohealEnabled:false,customerOrganization:{id:$customer_id}}' >"${body}"
  else
    jq -n --arg name "${name}" \
      '{name:$name,type:"docker",deployments:[],metricsEnabled:false,imageCleanupEnabled:false,deploymentLogsEnabled:true,autohealEnabled:false}' >"${body}"
  fi
  distr_api_request POST "/deployment-targets" "${body}"
  rm -f "${body}"
}

distr_ensure_docker_target() {
  local name="$1"
  local target count
  DISTR_TARGET_CREATED=0
  export DISTR_TARGET_CREATED
  target="$(distr_find_target_by_name "${name}")"
  if [[ -n "${target}" ]]; then
    count="$(jq -s 'length' <<<"${target}")"
    [[ "${count}" == "1" ]] || azgw_die "multiple Distr deployment targets named ${name}"
    jq -e '.type == "docker"' <<<"${target}" >/dev/null \
      || azgw_die "Distr target ${name} exists but is not type docker"
    printf '%s\n' "${target}"
    return 0
  fi
  if [[ "${DISTR_DRY_RUN}" == "1" ]]; then
    DISTR_TARGET_CREATED=1
    export DISTR_TARGET_CREATED
    jq -n --arg name "${name}" '{id:"dry-run-target",name:$name,type:"docker",deployments":[]}'
    return 0
  fi
  DISTR_TARGET_CREATED=1
  export DISTR_TARGET_CREATED
  distr_create_docker_target "${name}"
}

distr_request_target_access() {
  local target_id="$1"
  local body
  body="$(mktemp)"
  chmod 600 "${body}"
  printf '{}\n' >"${body}"
  distr_api_request POST "/deployment-targets/${target_id}/access-request" "${body}"
  rm -f "${body}"
}

distr_put_docker_deployment() {
  local target_json="$1"
  local app_version_id="$2"
  local env_file="$3"
  local body env_b64 deployment_id
  body="$(mktemp)"
  chmod 600 "${body}"
  env_b64="$(azgw_json_b64 <"${env_file}")"
  deployment_id="$(jq -r --arg app "${INFRA_APPLICATION_ID}" '
    .deployments // []
    | map(select(.application.id == $app))
    | .[0].id // empty
  ' <<<"${target_json}")"
  jq -n \
    --arg target_id "$(jq -r '.id' <<<"${target_json}")" \
    --arg deployment_id "${deployment_id}" \
    --arg version_id "${app_version_id}" \
    --arg env_file_data "${env_b64}" \
    '{
      deploymentTargetId: $target_id,
      applicationVersionId: $version_id,
      dockerType: "compose",
      envFileData: $env_file_data,
      forceRestart: true
    } + (if $deployment_id != "" then {deploymentId: $deployment_id} else {} end)' \
    >"${body}"
  distr_api_request PUT "/deployments" "${body}" >/dev/null
  rm -f "${body}"
}

azgw_install_docker_agent() {
  local connect_url="$1"
  local command protected settings
  command="curl -fsSL $(printf '%q' "${connect_url}") | docker compose -f - up -d"
  protected="$(jq -n --arg command "${command}" '{commandToExecute: $command}')"
  settings="$(jq -n --arg ts "$(date +%s)" '{timestamp: $ts}')"
  if [[ "${DISTR_DRY_RUN}" == "1" ]]; then
    azgw_log "DRY_RUN would install Docker agent on ${VM_NAME} through protected CustomScript settings"
    return 0
  fi
  az vm extension set \
    --resource-group "${RESOURCE_GROUP_NAME}" \
    --vm-name "${VM_NAME}" \
    --publisher Microsoft.Azure.Extensions \
    --name CustomScript \
    --settings "${settings}" \
    --protected-settings "${protected}" \
    --only-show-errors >/dev/null
}

azgw_wait_distr_deployment() {
  local target_id="$1"
  local app_id="$2"
  local target status deadline
  if [[ "${NO_WAIT:-0}" == "1" || "${DISTR_DRY_RUN}" == "1" ]]; then
    return 0
  fi
  deadline=$((SECONDS + 7200))
  while (( SECONDS < deadline )); do
    target="$(distr_api_request GET "/deployment-targets/${target_id}")" || true
    status="$(jq -r --arg app "${app_id}" '
      .deployments // []
      | map(select(.application.id == $app))
      | .[0].latestStatus.type // ""
    ' <<<"${target:-{}}")"
    case "${status}" in
      healthy)
        return 0
        ;;
      error)
        azgw_die "Distr reports the Azure infra deployment is in error"
        ;;
    esac
    azgw_log "waiting for infra runner (latest status: ${status:-pending})"
    sleep 30
  done
  azgw_die "Azure infra deployment did not become healthy within 120 minutes"
}
