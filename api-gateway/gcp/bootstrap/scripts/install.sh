#!/usr/bin/env bash
# Interactive production GCP installation guide.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BOOTSTRAP_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
GCP_DIR="$(cd "${BOOTSTRAP_DIR}/.." && pwd)"
SAMPLE_ENV="${GCP_DIR}/sample-gateway-infra.env"
GENERATED_ENV="${GCP_DIR}/.generated/gateway-infra.env"
INSTALL_TOTAL_STEPS=9
INSTALL_MODE="run"
INSTALL_FROM_STEP=1

install_usage() {
  cat <<'EOF'
usage: install.sh [--from-step N]
       install.sh --list-steps
       install.sh --check

Runs the production-only GCP install as an interactive checklist. The CLI runs
the local GCP/bootstrap commands and pauses for the required Distr Hub actions.
It never writes Hub connect URLs or resolved secrets to disk.

Options:
  --from-step N  Resume at step N (1-9). Earlier steps must be complete.
  --list-steps   Print the step names without performing any action.
  --check        Validate the local CLI/runbook files without cloud access.
  -h, --help     Show this help.

Optional environment defaults:
  INFRA_DEPLOY_NAME, GATEWAY_DEPLOY_NAME, DOMAIN_NAME,
  CLOUDSQL_INSTANCE, REDIS_INSTANCE, QUOTA_PROJECT_ID
EOF
}

install_list_steps() {
  cat <<'EOF'
1  Confirm entitlements, account inputs, naming, quota, and capacity
2  Install gcloud tools and authenticate the human user plus ADC
3  Configure and apply the production project/bootstrap foundation
4  Create Hub Secrets and the api-gateway-infra Docker deployment
5  Connect the Docker agent and complete the first infra deployment
6  Create the api-gateway Helm deployment and connect its Kubernetes agent
7  Enable gateway auto-deploy and complete the second infra deployment
8  Verify dashboard login, provider configuration, and a test chat
9  Run optional smoke checks and record the handoff
EOF
}

install_die() {
  printf 'ERROR: %s\n' "$*" >&2
  return 1
}

install_parse_args() {
  INSTALL_MODE="run"
  INSTALL_FROM_STEP=1

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --from-step)
        [[ $# -ge 2 ]] || {
          install_usage >&2
          return 2
        }
        INSTALL_FROM_STEP="$2"
        shift 2
        ;;
      --list-steps)
        INSTALL_MODE="list"
        shift
        ;;
      --check)
        INSTALL_MODE="check"
        shift
        ;;
      -h|--help)
        INSTALL_MODE="help"
        shift
        ;;
      *)
        printf 'ERROR: unknown argument: %s\n' "$1" >&2
        install_usage >&2
        return 2
        ;;
    esac
  done

  if [[ ! "${INSTALL_FROM_STEP}" =~ ^[1-9]$ ]]; then
    printf 'ERROR: --from-step must be an integer from 1 to %s\n' \
      "${INSTALL_TOTAL_STEPS}" >&2
    return 2
  fi
  if [[ "${INSTALL_MODE}" != "run" && "${INSTALL_FROM_STEP}" -ne 1 ]]; then
    printf 'ERROR: --from-step cannot be combined with --%s\n' \
      "${INSTALL_MODE}" >&2
    return 2
  fi
}

install_assert_dns1123() {
  local value="${1:-}"
  local label="${2:-value}"
  if [[ ! "${value}" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]]; then
    printf 'ERROR: %s must be a lowercase DNS-1123 label (got: %s)\n' \
      "${label}" "${value}" >&2
    return 2
  fi
}

install_assert_deployment_name() {
  local value="${1:-}"
  local label="${2:-deployment name}"
  install_assert_dns1123 "${value}" "${label}" || return
  if [[ "${#value}" -gt 32 ]]; then
    printf 'ERROR: %s must be at most 32 characters\n' "${label}" >&2
    return 2
  fi
}

install_validate_connect_url() {
  local value="${1:-}"
  [[ "${value}" =~ ^https://app\.distr\.sh/api/v1/connect\?[^[:space:]]+$ ]] || {
    printf 'ERROR: expected an https://app.distr.sh/api/v1/connect URL\n' >&2
    return 2
  }
}

install_validate_hub_command() {
  local value="${1:-}"
  [[ "${value}" =~ kubectl[[:space:]]+apply ]] \
    && [[ "${value}" =~ -n[[:space:]]+[a-z0-9]([-a-z0-9]*[a-z0-9])? ]] \
    && [[ "${value}" =~ https://app\.distr\.sh/api/v1/connect\? ]] || {
    printf 'ERROR: paste the complete Hub kubectl apply -n ... connect command\n' >&2
    return 2
  }
}

install_validate_hub_namespace() {
  local value="${1:-}"
  local expected="${2:-}"
  local actual=""
  if [[ "${value}" =~ -n[[:space:]]+([a-z0-9]([-a-z0-9]*[a-z0-9])?) ]]; then
    actual="${BASH_REMATCH[1]}"
  fi
  if [[ -z "${expected}" || "${actual}" != "${expected}" ]]; then
    printf 'ERROR: Hub command namespace must be %s (got: %s)\n' \
      "${expected:-<empty>}" "${actual:-<missing>}" >&2
    return 2
  fi
}

install_validate_hostname() {
  local value="${1:-}"
  if [[ ! "${value}" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]] \
    || [[ "${value}" != *.* || "${value}" == *..* ]]; then
    printf 'ERROR: enter a hostname such as api.example.com (without https://)\n' >&2
    return 2
  fi
}

install_check_files() {
  local script
  for script in \
    bootstrap.sh \
    connect-k8s-agent.sh \
    install-gcloud.sh \
    run-agent.sh \
    setup-gcloud.sh \
    smoke-checks.sh; do
    [[ -x "${SCRIPT_DIR}/${script}" ]] \
      || install_die "required executable is missing: ${SCRIPT_DIR}/${script}"
  done
  [[ -r "${BOOTSTRAP_DIR}/terraform.tfvars.example" ]] \
    || install_die "terraform.tfvars.example is missing"
  [[ -r "${SAMPLE_ENV}" ]] || install_die "sample gateway environment is missing"
  grep -Fxq 'CLOUD=gcp' "${SAMPLE_ENV}" \
    || install_die "sample gateway environment is not the GCP template"
  grep -Fxq 'GATEWAY_AUTO_DEPLOY=false' "${SAMPLE_ENV}" \
    || install_die "sample gateway environment must start with auto-deploy off"
  grep -Fxq 'DISTR_DRY_RUN=0' "${SAMPLE_ENV}" \
    || install_die "sample gateway environment must use the normal apply workflow"
  printf '[install] local CLI contract is ready\n'
}

install_header() {
  local number="$1"
  local title="$2"
  printf '\n============================================================\n'
  printf 'Step %s/%s: %s\n' "${number}" "${INSTALL_TOTAL_STEPS}" "${title}"
  printf '============================================================\n'
}

install_require_terminal() {
  [[ -t 0 && -t 1 ]] || install_die \
    'the installer is interactive; run it from a terminal (use --check in automation)'
}

install_wait_for_word() {
  local prompt="$1"
  local expected="${2:-done}"
  local reply
  while true; do
    printf '%s\n' "${prompt}"
    printf "Type '%s' to continue: " "${expected}"
    read -r reply
    if [[ "${reply}" == "${expected}" ]]; then
      return 0
    fi
    printf "Waiting; enter exactly '%s' after the checkpoint is complete.\n" \
      "${expected}"
  done
}

install_prompt_optional() {
  local variable_name="$1"
  local label="$2"
  local current="${!variable_name:-}"
  local value
  if [[ -n "${current}" ]]; then
    printf '%s [%s]: ' "${label}" "${current}"
  else
    printf '%s (optional, press Enter to skip): ' "${label}"
  fi
  read -r value
  printf -v "${variable_name}" '%s' "${value:-${current}}"
}

install_prompt_dns1123() {
  local variable_name="$1"
  local label="$2"
  local current="${!variable_name:-}"
  local value
  while true; do
    if [[ -n "${current}" ]]; then
      printf '%s [%s]: ' "${label}" "${current}"
    else
      printf '%s: ' "${label}"
    fi
    read -r value
    value="${value:-${current}}"
    if install_assert_dns1123 "${value}" "${label}"; then
      printf -v "${variable_name}" '%s' "${value}"
      return 0
    fi
  done
}

install_prompt_deployment_name() {
  local variable_name="$1"
  local label="$2"
  local current="${!variable_name:-}"
  local value
  while true; do
    if [[ -n "${current}" ]]; then
      printf '%s [%s]: ' "${label}" "${current}"
    else
      printf '%s: ' "${label}"
    fi
    read -r value
    value="${value:-${current}}"
    if install_assert_deployment_name "${value}" "${label}"; then
      printf -v "${variable_name}" '%s' "${value}"
      return 0
    fi
  done
}

install_prompt_value() {
  local variable_name="$1"
  local label="$2"
  local current="${!variable_name:-}"
  local value
  while true; do
    if [[ -n "${current}" ]]; then
      printf '%s [%s]: ' "${label}" "${current}"
    else
      printf '%s: ' "${label}"
    fi
    read -r value
    value="${value:-${current}}"
    if [[ -n "${value}" ]]; then
      printf -v "${variable_name}" '%s' "${value}"
      return 0
    fi
    printf 'A value is required.\n'
  done
}

install_prompt_hostname() {
  local variable_name="$1"
  local label="$2"
  local current="${!variable_name:-}"
  local value
  while true; do
    if [[ -n "${current}" ]]; then
      printf '%s [%s]: ' "${label}" "${current}"
    else
      printf '%s: ' "${label}"
    fi
    read -r value
    value="${value:-${current}}"
    if install_validate_hostname "${value}"; then
      printf -v "${variable_name}" '%s' "${value}"
      return 0
    fi
  done
}

install_prompt_bool() {
  local variable_name="$1"
  local label="$2"
  local current="${!variable_name:-true}"
  local value
  while true; do
    printf '%s [true/false, default %s]: ' "${label}" "${current}"
    read -r value
    value="${value:-${current}}"
    case "${value}" in
      true|false)
        printf -v "${variable_name}" '%s' "${value}"
        return 0
        ;;
      *) printf 'Enter true or false.\n' ;;
    esac
  done
}

install_bootstrap_output() {
  local output_name="$1"
  local value
  value="$(terraform -chdir="${BOOTSTRAP_DIR}" output -raw "${output_name}" 2>/dev/null)" \
    || install_die \
      "could not read Terraform output ${output_name}; complete step 3 first"
  [[ -n "${value}" && "${value}" != "null" ]] \
    || install_die "Terraform output is empty: ${output_name}"
  printf '%s\n' "${value}"
}

install_render_gateway_env() {
  local output_file="$1"
  local temporary_file="${output_file}.tmp.$$"
  local line
  mkdir -p "$(dirname "${output_file}")"
  umask 077
  while IFS= read -r line || [[ -n "${line}" ]]; do
    case "${line}" in
      DEPLOY_NAME=*) printf 'DEPLOY_NAME=%s\n' "${INFRA_DEPLOY_NAME}" ;;
      GATEWAY_DISTR_DEPLOYMENT_NAME=*)
        printf 'GATEWAY_DISTR_DEPLOYMENT_NAME=%s\n' "${GATEWAY_DEPLOY_NAME}"
        ;;
      GCP_PROJECT=*) printf 'GCP_PROJECT=%s\n' "${GCP_PROJECT}" ;;
      GCP_REGION=*) printf 'GCP_REGION=%s\n' "${GCP_REGION}" ;;
      GCP_DNS_PROJECT_ID=*)
        printf 'GCP_DNS_PROJECT_ID=%s\n' "${GCP_DNS_PROJECT_ID}"
        ;;
      DOMAIN_NAME=*) printf 'DOMAIN_NAME=%s\n' "${DOMAIN_NAME}" ;;
      DNS_ZONE_NAME=*) printf 'DNS_ZONE_NAME=%s\n' "${DNS_ZONE_NAME}" ;;
      TF_STATE_BUCKET=*) printf 'TF_STATE_BUCKET=%s\n' "${TF_STATE_BUCKET}" ;;
      VPC_CIDR=*) printf 'VPC_CIDR=%s\n' "${VPC_CIDR}" ;;
      DATADOG_ENABLED=*) printf 'DATADOG_ENABLED=%s\n' "${DATADOG_ENABLED}" ;;
      DATADOG_ENV=*) printf 'DATADOG_ENV=%s\n' "${GCP_PROJECT}" ;;
      DATADOG_GCP_CLOUD_METRICS_ENABLED=*)
        printf 'DATADOG_GCP_CLOUD_METRICS_ENABLED=%s\n' "${DATADOG_ENABLED}"
        ;;
      GATEWAY_ROUTE_ALLOWED_HOST_SUFFIXES=*)
        printf 'GATEWAY_ROUTE_ALLOWED_HOST_SUFFIXES=%s\n' \
          "${GATEWAY_ROUTE_ALLOWED_HOST_SUFFIXES}"
        ;;
      *) printf '%s\n' "${line}" ;;
    esac
  done <"${SAMPLE_ENV}" >"${temporary_file}"
  mv "${temporary_file}" "${output_file}"
  chmod 0600 "${output_file}"
}

install_read_secret() {
  local variable_name="$1"
  local prompt="$2"
  local value
  printf '%s (input hidden): ' "${prompt}"
  read -r -s value
  printf '\n'
  printf -v "${variable_name}" '%s' "${value}"
}

install_should_run() {
  [[ "$1" -ge "${INSTALL_FROM_STEP}" ]]
}

install_step_1() {
  install_header 1 'Confirm prerequisites'
  cat <<'EOF'
Confirm with your Subconscious contact that the customer organization is
entitled to the GCP api-gateway-infra runner, gateway chart, and all referenced
images. Have the organization/folder, billing account, shared DNS project and
zone, production hostname, RFC1918 ranges, operator principals, and N4A quota
approval ready.
EOF
  install_wait_for_word 'Complete those checks before continuing.' ready
}

install_step_2() {
  install_header 2 'Install tools and authenticate'
  "${SCRIPT_DIR}/install-gcloud.sh"
  install_prompt_optional QUOTA_PROJECT_ID \
    'Existing quota project ID for ADC/API enablement'
  if [[ -n "${QUOTA_PROJECT_ID:-}" ]]; then
    "${SCRIPT_DIR}/setup-gcloud.sh" --quota-project "${QUOTA_PROJECT_ID}"
  else
    "${SCRIPT_DIR}/setup-gcloud.sh"
  fi
}

install_step_3() {
  local editor_text editor_command
  local editor_parts=()
  install_header 3 'Apply the production foundation'
  if [[ ! -f "${BOOTSTRAP_DIR}/terraform.tfvars" ]]; then
    cp "${BOOTSTRAP_DIR}/terraform.tfvars.example" \
      "${BOOTSTRAP_DIR}/terraform.tfvars"
    printf '[install] created %s from the checked-in example\n' \
      "${BOOTSTRAP_DIR}/terraform.tfvars"
  fi
  editor_text="${VISUAL:-${EDITOR:-vi}}"
  read -r -a editor_parts <<<"${editor_text}"
  editor_command="${editor_parts[0]:-vi}"
  command -v "${editor_command}" >/dev/null 2>&1 \
    || install_die "editor is not available: ${editor_command}"
  printf '[install] opening terraform.tfvars with %s\n' "${editor_text}"
  "${editor_parts[@]}" "${BOOTSTRAP_DIR}/terraform.tfvars"
  "${SCRIPT_DIR}/bootstrap.sh"
}

install_step_4() {
  install_header 4 'Create Hub Secrets and the infra deployment'
  install_prompt_deployment_name INFRA_DEPLOY_NAME 'Infra Docker deployment name'
  install_prompt_deployment_name GATEWAY_DEPLOY_NAME 'Gateway deployment/namespace name'
  GCP_PROJECT="$(install_bootstrap_output project_id)"
  GCP_REGION="$(install_bootstrap_output region)"
  GCP_DNS_PROJECT_ID="$(install_bootstrap_output dns_project_id)"
  TF_STATE_BUCKET="$(install_bootstrap_output state_bucket)"
  install_prompt_hostname DOMAIN_NAME 'Production gateway hostname'
  install_prompt_value DNS_ZONE_NAME 'Cloud DNS managed-zone resource name'
  VPC_CIDR="${VPC_CIDR:-10.60.0.0/16}"
  install_prompt_value VPC_CIDR 'Production platform RFC1918 /16'
  install_prompt_value GATEWAY_ROUTE_ALLOWED_HOST_SUFFIXES \
    'Allowed external provider DNS suffixes (comma-separated)'
  DATADOG_ENABLED="${DATADOG_ENABLED:-true}"
  install_prompt_bool DATADOG_ENABLED 'Enable Datadog'
  install_render_gateway_env "${GENERATED_ENV}"
  cat <<EOF
In Distr Hub:
  1. Create masked Secrets: DISTR_TOKEN and, when Datadog is enabled,
     DD_API_KEY and DD_APP_KEY.
  2. Optionally create GATEWAY_DASHBOARD_BOOTSTRAP_PASSWORD. For OIDC, create
     GCP_GATEWAY_DASHBOARD_OIDC_CLIENT_SECRET and reference it from
     DASHBOARD_OIDC_CLIENT_SECRET in the generated environment.
  3. Create the api-gateway-infra Docker deployment named:
       ${INFRA_DEPLOY_NAME}
  4. Paste this generated environment into the deployment:
       ${GENERATED_ENV}
     It already contains the production Terraform outputs and your choices.
  5. Review optional dashboard, OIDC, webhook, and hosted-auth fields. Keep
     GATEWAY_AUTO_DEPLOY=false and DISTR_DRY_RUN=0.
  6. Save the deployment and copy its Docker target connect URL.

Never put a Google service-account JSON file or resolved application secret in
Hub.
EOF
  install_wait_for_word 'Create and save the Hub resources above.' 'done'
}

install_step_5() {
  local docker_connect_url=""
  install_header 5 'Connect Docker and run the first infra deployment'
  install_prompt_deployment_name INFRA_DEPLOY_NAME 'Infra Docker deployment name'
  install_read_secret docker_connect_url \
    'Paste the Docker target https://app.distr.sh/api/v1/connect URL'
  install_validate_connect_url "${docker_connect_url}"
  "${SCRIPT_DIR}/run-agent.sh" "${docker_connect_url}"
  unset docker_connect_url
  cat <<'EOF'
In Distr Hub, verify the Docker target is connected and trigger the infra
deployment. Keep GATEWAY_AUTO_DEPLOY=false. Wait for the run to finish and for
GKE to exist before continuing.
EOF
  install_wait_for_word 'Confirm the first infra deployment completed successfully.' 'done'
}

install_step_6() {
  local hub_command=""
  install_header 6 'Create the Helm deployment and connect Kubernetes'
  install_prompt_deployment_name INFRA_DEPLOY_NAME 'Infra Docker deployment name'
  install_prompt_deployment_name GATEWAY_DEPLOY_NAME 'Gateway deployment/namespace name'
  cat <<EOF
In Distr Hub, create the api-gateway Helm deployment. Use
${GATEWAY_DEPLOY_NAME} for the namespace and Helm release. Leave Helm values
empty because the infra runner owns them. Deploy once, then copy the complete
Kubernetes target command beginning with:

  kubectl apply -n ${GATEWAY_DEPLOY_NAME} -f "https://app.distr.sh/api/v1/connect?..."
EOF
  install_read_secret hub_command 'Paste the complete Hub kubectl apply command'
  install_validate_hub_command "${hub_command}"
  install_validate_hub_namespace "${hub_command}" "${GATEWAY_DEPLOY_NAME}"
  "${SCRIPT_DIR}/connect-k8s-agent.sh" "${INFRA_DEPLOY_NAME}" "${hub_command}"
  unset hub_command
}

install_step_7() {
  install_header 7 'Run the second infra deployment'
  cat <<'EOF'
In the api-gateway-infra Hub environment:
  1. Set GATEWAY_AUTO_DEPLOY=true.
  2. Keep GATEWAY_CHART_VERSION=latest, or select an approved named version.
  3. Trigger the infra deployment again.
  4. Wait for Terraform, ESO secret synchronization, the Helm deployment, the
     managed certificate, and public readiness to complete.
EOF
  install_wait_for_word 'Confirm the second infra deployment completed successfully.' 'done'
}

install_step_8() {
  install_header 8 'Verify the dashboard and a test chat'
  cat <<'EOF'
Open https://<DOMAIN_NAME>/dashboard, sign in with the bootstrap administrator
or OIDC, invite the required users, configure the approved provider or hosted
GPU key, and run one successful test chat. Do not continue on a failed login,
provider error, or empty response.
EOF
  install_wait_for_word 'Confirm dashboard login and the test chat succeeded.' 'done'
}

install_step_9() {
  local run_smoke
  install_header 9 'Smoke checks and handoff'
  printf 'Run the read-only platform smoke checks now? [y/N]: '
  read -r run_smoke
  case "${run_smoke}" in
    y|Y|yes|YES)
      install_prompt_deployment_name INFRA_DEPLOY_NAME 'Infra Docker deployment name'
      install_prompt_deployment_name GATEWAY_DEPLOY_NAME 'Gateway deployment/namespace name'
      install_prompt_hostname DOMAIN_NAME 'Production gateway hostname'
      CLOUDSQL_INSTANCE="${CLOUDSQL_INSTANCE:-${INFRA_DEPLOY_NAME}-postgres}"
      REDIS_INSTANCE="${REDIS_INSTANCE:-${INFRA_DEPLOY_NAME}-redis}"
      install_prompt_dns1123 CLOUDSQL_INSTANCE 'Cloud SQL instance name'
      install_prompt_dns1123 REDIS_INSTANCE 'Redis instance name'
      "${SCRIPT_DIR}/smoke-checks.sh" \
        "${INFRA_DEPLOY_NAME}" \
        "${GATEWAY_DEPLOY_NAME}" \
        "${DOMAIN_NAME}" \
        "${CLOUDSQL_INSTANCE}" \
        "${REDIS_INSTANCE}"
      ;;
    *)
      printf '[install] smoke checks skipped; run scripts/smoke-checks.sh later\n'
      ;;
  esac
  cat <<'EOF'

Record the production project, DNS/hostname, CIDRs, state bucket, Distr release
versions, GKE/Cloud SQL/Redis identifiers, IAM reviewers, Datadog state, smoke
evidence, and rollback/upgrade owners. The production install is complete.
EOF
}

install_main() {
  local step
  install_parse_args "$@" || return
  case "${INSTALL_MODE}" in
    help) install_usage; return 0 ;;
    list) install_list_steps; return 0 ;;
    check) install_check_files; return 0 ;;
  esac

  install_require_terminal
  install_check_files
  printf '\nSubconscious Inference System - production GCP installer\n'
  printf 'Starting at step %s. No connect URL or resolved secret is stored.\n' \
    "${INSTALL_FROM_STEP}"

  for step in $(seq 1 "${INSTALL_TOTAL_STEPS}"); do
    if install_should_run "${step}"; then
      "install_step_${step}"
    fi
  done
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  install_main "$@"
fi
