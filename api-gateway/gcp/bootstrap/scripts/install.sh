#!/usr/bin/env bash
# Interactive production GCP installation guide.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BOOTSTRAP_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
GCP_DIR="$(cd "${BOOTSTRAP_DIR}/.." && pwd)"
SAMPLE_ENV="${GCP_DIR}/sample-gateway-infra.env"
GENERATED_ENV="${GCP_DIR}/.generated/gateway-infra.env"
GENERATED_AUTO_DEPLOY_ENV="${GCP_DIR}/.generated/gateway-infra-auto-deploy.env"
INSTALL_TOTAL_STEPS=10
INSTALL_MODE="run"
INSTALL_FROM_STEP=1
INSTALL_POLL_SECONDS="${INSTALL_POLL_SECONDS:-30}"
INSTALL_GKE_WAIT_SECONDS="${INSTALL_GKE_WAIT_SECONDS:-3600}"
INSTALL_CERT_WAIT_SECONDS="${INSTALL_CERT_WAIT_SECONDS:-3600}"

install_usage() {
  cat <<'EOF'
usage: install.sh [--from-step N]
       install.sh --list-steps
       install.sh --check

Runs the production-only GCP install as an interactive checklist. The CLI runs
the local GCP/bootstrap commands and pauses for the required Distr Hub actions.
It never writes Hub PATs, API keys, passwords, or connect credentials to the
repository or generated env. Google login stores user ADC only in gcloud's
standard protected user configuration.

Options:
  --from-step N  Resume at step N (1-10). Earlier steps must be complete.
  --list-steps   Print the step names without performing any action.
  --check        Validate the local CLI/runbook files without cloud access.
  -h, --help     Show this help.

Optional environment defaults:
  INFRA_DEPLOY_NAME, GATEWAY_DEPLOY_NAME, DOMAIN_NAME,
  CLOUDSQL_INSTANCE, REDIS_INSTANCE, DATADOG_ENABLED
  Later steps also reuse identifiers from .generated/gateway-infra.env.
EOF
}

install_list_steps() {
  cat <<'EOF'
1   Confirm entitlements, account inputs, naming, quota, and capacity
2   Install gcloud tools and authenticate the human user plus ADC
3   Configure and apply the production project/bootstrap foundation
4   Collect Distr inputs, then create the infra app and Hub Secrets
5   Connect the Docker agent and complete the first infra deployment
6   Create the gateway Helm app and connect the Kubernetes agent
7   Enable gateway auto-deploy and complete the second infra deployment
8   Verify dashboard login, provider configuration, and a test chat
9   Run platform, Secret Manager, ESO, rollout, and endpoint verification
10  Record the production handoff and ownership
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

  if [[ ! "${INSTALL_FROM_STEP}" =~ ^[0-9]+$ ]] \
    || [[ "${INSTALL_FROM_STEP}" -lt 1 ]] \
    || [[ "${INSTALL_FROM_STEP}" -gt "${INSTALL_TOTAL_STEPS}" ]]; then
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
  if [[ "${value}" == *\"* || "${value}" == *\'* || "${value}" == *\\* ]]; then
    printf 'ERROR: connect URL contains an unsafe quote or backslash\n' >&2
    return 2
  fi
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

install_validate_https_url() {
  local value="${1:-}"
  local label="${2:-URL}"
  if [[ ! "${value}" =~ ^https://[^/[:space:]]+(/[^[:space:]]*)?$ ]]; then
    printf 'ERROR: %s must be a complete https:// URL\n' "${label}" >&2
    return 2
  fi
  if [[ "${value}" == *\"* || "${value}" == *\'* || "${value}" == *\\* ]]; then
    printf 'ERROR: %s contains an unsafe quote or backslash\n' "${label}" >&2
    return 2
  fi
}

install_validate_rfc1918_cidr() {
  local value="${1:-}"
  local expected_prefix="${2:-}"
  local label="${3:-CIDR}"
  local address prefix a b c d octet
  if [[ ! "${value}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$ ]]; then
    printf 'ERROR: %s must be an IPv4 CIDR\n' "${label}" >&2
    return 2
  fi
  address="${value%/*}"
  prefix="${value#*/}"
  IFS=. read -r a b c d <<<"${address}"
  for octet in "${a}" "${b}" "${c}" "${d}"; do
    if [[ ! "${octet}" =~ ^(0|[1-9][0-9]{0,2})$ ]]; then
      printf 'ERROR: %s contains a non-canonical IPv4 octet\n' "${label}" >&2
      return 2
    fi
    if [[ "${octet}" -gt 255 ]]; then
      printf 'ERROR: %s contains an invalid IPv4 octet\n' "${label}" >&2
      return 2
    fi
  done
  if [[ "${prefix}" != "${expected_prefix}" ]]; then
    printf 'ERROR: %s must use /%s\n' "${label}" "${expected_prefix}" >&2
    return 2
  fi
  if ! { [[ "${a}" -eq 10 ]] \
    || [[ "${a}" -eq 172 && "${b}" -ge 16 && "${b}" -le 31 ]] \
    || [[ "${a}" -eq 192 && "${b}" -eq 168 ]]; }; then
    printf 'ERROR: %s must be inside RFC1918 private address space\n' "${label}" >&2
    return 2
  fi
  if [[ "${expected_prefix}" -eq 16 && ( "${c}" -ne 0 || "${d}" -ne 0 ) ]] \
    || [[ "${expected_prefix}" -eq 24 && "${d}" -ne 0 ]]; then
    printf 'ERROR: %s must be a canonical network with no host bits\n' \
      "${label}" >&2
    return 2
  fi
}

install_validate_cidrs_do_not_overlap() {
  local platform_cidr="$1"
  local bootstrap_cidr="$2"
  local platform_address bootstrap_address
  local platform_octets=() bootstrap_octets=()
  platform_address="${platform_cidr%/*}"
  bootstrap_address="${bootstrap_cidr%/*}"
  IFS=. read -r -a platform_octets <<<"${platform_address}"
  IFS=. read -r -a bootstrap_octets <<<"${bootstrap_address}"
  if [[ "${platform_octets[0]}" -eq "${bootstrap_octets[0]}" \
    && "${platform_octets[1]}" -eq "${bootstrap_octets[1]}" ]]; then
    printf 'ERROR: platform /16 overlaps bootstrap subnet %s\n' \
      "${bootstrap_cidr}" >&2
    return 2
  fi
}

install_validate_provider_suffixes() {
  local value="${1:-}"
  local item
  local items=()
  IFS=',' read -r -a items <<<"${value}"
  [[ "${#items[@]}" -gt 0 ]] || return 2
  for item in "${items[@]}"; do
    item="${item#.}"
    if [[ ! "${item}" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]] \
      || [[ "${item}" != *.* || "${item}" == *..* ]]; then
      printf 'ERROR: provider suffixes must be comma-separated DNS names, not URLs\n' >&2
      return 2
    fi
  done
}

install_load_existing_project_context() {
  local project_id="$1"
  local billing_json billing_name lifecycle_state project_json
  project_json="$(gcloud projects describe "${project_id}" --format=json)" \
    || install_die "cannot read existing project: ${project_id}"
  lifecycle_state="$(jq -r '.lifecycleState // ""' <<<"${project_json}")"
  [[ "${lifecycle_state}" == "ACTIVE" ]] \
    || install_die "selected project is not ACTIVE: ${project_id}"

  billing_json="$(gcloud billing projects describe "${project_id}" --format=json)" \
    || install_die "cannot read billing for existing project: ${project_id}"
  [[ "$(jq -r '.billingEnabled // false' <<<"${billing_json}")" == "true" ]] \
    || install_die "billing is not enabled on existing project: ${project_id}"
  billing_name="$(jq -r '.billingAccountName // ""' <<<"${billing_json}")"
  BILLING_ACCOUNT_ID="${billing_name##*/}"
  install_validate_billing_account_id "${BILLING_ACCOUNT_ID}"
}

install_validate_billing_account_id() {
  local value="${1:-}"
  [[ "${value}" =~ ^[0-9A-Fa-f]{6}-[0-9A-Fa-f]{6}-[0-9A-Fa-f]{6}$ ]] || {
    printf 'ERROR: billing account ID must look like 000000-000000-000000\n' >&2
    return 2
  }
}

install_validate_gcp_project_id() {
  local value="${1:-}"
  local label="${2:-project ID}"
  [[ "${value}" =~ ^[a-z][a-z0-9-]{4,28}[a-z0-9]$ ]] || {
    printf 'ERROR: %s must be a valid 6-30 character Google Cloud project ID\n' \
      "${label}" >&2
    return 2
  }
}

install_validate_bootstrap_zone() {
  local value="${1:-}"
  [[ "${value}" =~ ^us-east1-[a-z]$ ]] || {
    printf 'ERROR: bootstrap zone must be in us-east1, such as us-east1-b\n' >&2
    return 2
  }
}

install_validate_operator_principals() {
  local value="${1:-}"
  local item
  local items=()
  IFS=',' read -r -a items <<<"${value}"
  [[ "${#items[@]}" -gt 0 ]] || return 2
  for item in "${items[@]}"; do
    item="${item#"${item%%[![:space:]]*}"}"
    item="${item%"${item##*[![:space:]]}"}"
    if [[ ! "${item}" =~ ^(user|group):[^[:space:]\"\\]+@[^[:space:]\"\\]+$ ]]; then
      printf 'ERROR: principals must be comma-separated user:email or group:email values\n' >&2
      return 2
    fi
  done
}

install_secret_prefix() {
  printf '%s' "$1" \
    | tr '[:lower:]-' '[:upper:]_' \
    | sed -E 's/[^A-Z0-9_]+/_/g'
}

install_tfvar_string() {
  local key="$1"
  sed -nE \
    "s/^[[:space:]]*${key}[[:space:]]*=[[:space:]]*\"([^\"]*)\"[[:space:]]*$/\\1/p" \
    "${BOOTSTRAP_DIR}/terraform.tfvars" \
    | head -n 1
}

install_validate_tfvars() {
  local file="${BOOTSTRAP_DIR}/terraform.tfvars"
  local dns_project_id project_id
  [[ -r "${file}" ]] || install_die "terraform.tfvars is missing"

  if grep -Eq \
    '^[[:space:]]*(project_id[[:space:]]*=[[:space:]]*"example-gateway-prod"|dns_project_id[[:space:]]*=[[:space:]]*"example-shared-dns"|"group:gateway-platform@example\.com")' \
    "${file}"; then
    install_die \
      'terraform.tfvars still contains an example value; replace every customer-specific example'
  fi

  project_id="$(install_tfvar_string project_id)"
  dns_project_id="$(install_tfvar_string dns_project_id)"
  install_validate_gcp_project_id "${project_id}" 'project ID'
  install_validate_gcp_project_id "${dns_project_id}" 'DNS project ID'
  chmod 0600 "${file}"
}

install_tfvars_is_legacy() {
  local file="$1"
  local legacy_environment_label='sand''box'
  grep -Eq \
    "^[[:space:]]*(enabled_environments|production_project_id|${legacy_environment_label}_project_id|monthly_budget_amounts_usd|monthly_budget_amount_usd|billing_account_id|quota_project_id|bootstrap_zones|bootstrap_subnet_cidrs|organization_id|folder_id|project_name|project_deletion_policy)[[:space:]]*=" \
    "${file}"
}

install_replace_legacy_tfvars() {
  local file="${BOOTSTRAP_DIR}/terraform.tfvars"
  local archive_dir archive_file
  cat <<'EOF'

This checkout contains an ignored terraform.tfvars from the retired
multi-environment bootstrap. Git branch changes do not replace ignored files.
It cannot be used by the production-only stack and will not be opened.

The installer can move that file to a private temporary archive. The guided
questionnaire will then create a fresh production-only terraform.tfvars. Use
the archive only to look up approved production IDs; do not copy retired
environment fields.
EOF
  install_wait_for_word \
    'Replace the active legacy file with the production-only template.' replace
  archive_dir="$(mktemp -d "${TMPDIR:-/tmp}/orangeline-legacy-tfvars.XXXXXX")"
  chmod 0700 "${archive_dir}"
  archive_file="${archive_dir}/terraform.tfvars"
  mv "${file}" "${archive_file}"
  chmod 0600 "${archive_file}"
  printf '[install] previous local values archived temporarily at %s\n' \
    "${archive_file}"
  printf '[install] delete that temporary archive after verifying the new configuration\n'
}

install_archive_legacy_local_state() {
  local archive_dir file state_addresses
  [[ -f "${BOOTSTRAP_DIR}/terraform.tfstate" ]] || return 0
  state_addresses="$(
    terraform -chdir="${BOOTSTRAP_DIR}" state list 2>/dev/null || true
  )"
  grep -Eq '^google_project\.environment\["' <<<"${state_addresses}" \
    || return 0

  archive_dir="$(mktemp -d "${TMPDIR:-/tmp}/orangeline-legacy-state.XXXXXX")"
  chmod 0700 "${archive_dir}"
  for file in terraform.tfstate terraform.tfstate.backup .bootstrap.tfplan; do
    if [[ -e "${BOOTSTRAP_DIR}/${file}" ]]; then
      mv "${BOOTSTRAP_DIR}/${file}" "${archive_dir}/${file}"
      chmod 0600 "${archive_dir}/${file}"
    fi
  done
  cat <<EOF

[install] isolated old multi-environment Terraform state without changing any
cloud resources. The existing-project deployment will start with fresh state.
[install] previous local state archived at: ${archive_dir}
[install] keep that archive until the old resources have a separately approved
retention or teardown decision.
EOF
}

install_render_bootstrap_tfvars() {
  local output_file="$1"
  local temporary_file="${output_file}.tmp.$$"
  local item
  local principals=()
  umask 077
  {
    printf '# Generated by scripts/install.sh. Identifiers only; no secrets.\n\n'
    printf 'project_id = "%s"\n\n' "${FOUNDATION_PROJECT_ID}"
    printf 'dns_project_id = "%s"\n\n' "${FOUNDATION_DNS_PROJECT_ID}"
    printf 'region                = "us-east1"\n'
    printf 'bootstrap_zone        = "%s"\n' "${BOOTSTRAP_ZONE}"
    printf 'bootstrap_subnet_cidr = "%s"\n\n' "${BOOTSTRAP_SUBNET_CIDR}"
    printf 'bootstrap_machine_type = "e2-standard-2"\n'
    printf 'bootstrap_disk_size_gb = 40\n\n'
    printf 'operator_principals = [\n'
    IFS=',' read -r -a principals <<<"${OPERATOR_PRINCIPALS}"
    for item in "${principals[@]}"; do
      item="${item#"${item%%[![:space:]]*}"}"
      item="${item%"${item##*[![:space:]]}"}"
      printf '  "%s",\n' "${item}"
    done
    printf ']\n\n'
    printf 'protect_bootstrap_vms = true\n\n'
    printf 'labels = {\n'
    printf '  application = "subconscious-gateway"\n'
    printf '  managed-by  = "terraform"\n'
    printf '  owner       = "platform"\n'
    printf '}\n'
  } >"${temporary_file}"
  mv "${temporary_file}" "${output_file}"
  chmod 0600 "${output_file}"
}

install_collect_bootstrap_tfvars() {
  local active_account project_candidates
  local retired_environment_name='sand''box' retired_environment_short='s''box'
  cat <<'EOF'

Required production foundation inputs
-------------------------------------
The CLI will discover candidates where Google permits it and then ask for the
exact value. These are identifiers/configuration, not secrets.

REQUIRED:
  - one existing ACTIVE production project with billing already enabled;
  - an existing project that owns the approved public Cloud DNS zone;
  - a non-overlapping private /24 for the bootstrap VM;
  - at least one IAP/OS Login operator user or Google Group.

FIXED production safety values:
  - region us-east1, e2-standard-2/40 GiB bootstrap VM;
  - ADC quota uses the selected production project;
  - the selected project remains outside Terraform ownership;
  - bootstrap VM deletion protection enabled.
EOF

  project_candidates="$(
    gcloud projects list --filter='lifecycleState=ACTIVE' --format=json \
      --limit=100 2>/dev/null \
      | jq -r \
        --arg retired_name "${retired_environment_name}" \
        --arg retired_short "${retired_environment_short}" \
        '.[]
         | (((.projectId // "") + " " + (.name // "")) | ascii_downcase) as $identity
         | select(($identity | contains($retired_name)) | not)
         | select(($identity | contains($retired_short)) | not)
         | [(.projectId // ""), (.name // .projectId // "unnamed")]
         | @tsv' \
      || true
  )"
  cat <<'EOF'
Select the EXISTING project where the production gateway will be deployed.
Terraform will enable APIs and create the gateway foundation resources inside
it, but will never create, import, move, relabel, or delete the project itself.
The CLI reads the project's attached billing account automatically.
EOF
  install_prompt_candidate FOUNDATION_PROJECT_ID \
    'Required existing production project' "${project_candidates}" \
    install_validate_gcp_project_id 'production project ID'
  install_load_existing_project_context "${FOUNDATION_PROJECT_ID}"
  printf '[install] deployment project: %s\n' "${FOUNDATION_PROJECT_ID}"
  printf '[install] attached billing account: %s\n' "${BILLING_ACCOUNT_ID}"

  cat <<'EOF'

ADC quota will use the same existing production project automatically. This
attributes Google client-library API quota while Terraform administers that
project; there is no second project selection.
EOF
  "${SCRIPT_DIR}/setup-gcloud.sh" \
    --skip-login --quota-project "${FOUNDATION_PROJECT_ID}"

  cat <<'EOF'

The DNS project is an EXISTING project containing the public managed zone for
the gateway hostname. Select the deployment project when it owns the zone, or
select a shared DNS/network project when the zone is managed separately.
EOF
  install_prompt_candidate FOUNDATION_DNS_PROJECT_ID \
    'Required existing Cloud DNS project' "${project_candidates}" \
    install_validate_gcp_project_id \
    'DNS project ID'
  printf '\nManaged zones visible in %s:\n' "${FOUNDATION_DNS_PROJECT_ID}"
  gcloud dns managed-zones list --project "${FOUNDATION_DNS_PROJECT_ID}" \
    --format='table(name,dnsName,visibility)' || {
    printf 'WARNING: could not list zones; verify Cloud DNS access before apply\n' >&2
  }
  cat <<'EOF'
The exact managed-zone resource name and final hostname are collected in the
single Distr configuration step after the foundation is applied.
EOF

  BOOTSTRAP_ZONE="${BOOTSTRAP_ZONE:-us-east1-b}"
  install_prompt_validated BOOTSTRAP_ZONE \
    'Required bootstrap VM zone in us-east1' install_validate_bootstrap_zone
  BOOTSTRAP_SUBNET_CIDR="${BOOTSTRAP_SUBNET_CIDR:-10.40.0.0/24}"
  install_prompt_rfc1918_cidr BOOTSTRAP_SUBNET_CIDR \
    'Required non-overlapping bootstrap RFC1918 /24' 24
  printf 'Confirm this /24 does not overlap customer networks, VPNs, peerings, or the platform /16.\n'

  active_account="$(gcloud config get-value account 2>/dev/null || true)"
  if [[ -n "${active_account}" && "${active_account}" != "(unset)" ]]; then
    OPERATOR_PRINCIPALS="${OPERATOR_PRINCIPALS:-user:${active_account}}"
  fi
  cat <<'EOF'

Operators receive IAP tunnel and OS Login access to the private bootstrap VM.
Prefer a customer-managed Google Group for day-2 access. Enter one or more
comma-separated values, for example:
  group:gateway-platform@example.com,user:installer@example.com
EOF
  install_prompt_validated OPERATOR_PRINCIPALS \
    'Required operator principals' install_validate_operator_principals

  install_render_bootstrap_tfvars "${BOOTSTRAP_DIR}/terraform.tfvars"
  printf '\n[install] wrote production-only configuration: %s\n' \
    "${BOOTSTRAP_DIR}/terraform.tfvars"
  printf '[install] no PAT, password, API key, ADC, or JSON key was written\n'
}

install_review_tfvars() {
  local editor_text editor_command
  local editor_parts=()
  editor_text="${VISUAL:-${EDITOR:-vi}}"
  read -r -a editor_parts <<<"${editor_text}"
  editor_command="${editor_parts[0]:-vi}"
  command -v "${editor_command}" >/dev/null 2>&1 \
    || install_die "editor is not available: ${editor_command}"
  printf '[install] opening generated terraform.tfvars with %s\n' "${editor_text}"
  "${editor_parts[@]}" "${BOOTSTRAP_DIR}/terraform.tfvars"
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

install_prompt_validated() {
  local variable_name="$1"
  local label="$2"
  local validator="$3"
  shift 3
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
    if "${validator}" "${value}" "$@"; then
      printf -v "${variable_name}" '%s' "${value}"
      return 0
    fi
  done
}

install_print_candidates() {
  local candidates="$1"
  local candidate_value candidate_label display_id index=0
  while IFS=$'\t' read -r candidate_value candidate_label; do
    [[ -n "${candidate_value}" ]] || continue
    index=$((index + 1))
    display_id="${candidate_value#*:}"
    printf '  %d) %s  [ID: %s]\n' "${index}" \
      "${candidate_label:-unnamed}" "${display_id}"
  done <<<"${candidates}"
}

install_candidate_count() {
  local candidates="$1"
  local candidate_value candidate_label count=0
  while IFS=$'\t' read -r candidate_value candidate_label; do
    [[ -n "${candidate_value}" ]] || continue
    count=$((count + 1))
  done <<<"${candidates}"
  printf '%s' "${count}"
}

install_candidate_value() {
  local candidates="$1"
  local wanted_index="$2"
  local candidate_value candidate_label index=0
  while IFS=$'\t' read -r candidate_value candidate_label; do
    [[ -n "${candidate_value}" ]] || continue
    index=$((index + 1))
    if [[ "${index}" -eq "${wanted_index}" ]]; then
      printf '%s' "${candidate_value}"
      return 0
    fi
  done <<<"${candidates}"
  return 1
}

install_prompt_candidate() {
  local variable_name="$1"
  local label="$2"
  local candidates="$3"
  local validator="$4"
  shift 4
  local candidate_count choice selected selected_display_id
  printf '\n%s candidates visible to the active Google account:\n' "${label}"
  install_print_candidates "${candidates}"
  candidate_count="$(install_candidate_count "${candidates}")"
  if [[ "${candidate_count}" -eq 0 ]]; then
    printf '  No candidates were returned. Check access or enter the ID manually.\n'
    install_prompt_validated "${variable_name}" "${label} ID" \
      "${validator}" "$@"
    return
  fi
  while true; do
    printf 'Select 1-%s, or type m to enter an ID manually: ' \
      "${candidate_count}"
    read -r choice
    if [[ "${choice}" == "m" || "${choice}" == "M" ]]; then
      install_prompt_validated "${variable_name}" "${label} ID" \
        "${validator}" "$@"
      return
    fi
    if [[ "${choice}" =~ ^[0-9]+$ ]] \
      && selected="$(install_candidate_value "${candidates}" "${choice}")"; then
      if "${validator}" "${selected}" "$@"; then
        printf -v "${variable_name}" '%s' "${selected}"
        selected_display_id="${selected#*:}"
        printf '[install] selected ID: %s\n' "${selected_display_id}"
        return
      fi
    fi
    printf 'Choose a listed number or m for manual entry.\n'
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

install_prompt_https_url() {
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
    if install_validate_https_url "${value}" "${label}"; then
      printf -v "${variable_name}" '%s' "${value}"
      return 0
    fi
  done
}

install_prompt_provider_suffixes() {
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
    if install_validate_provider_suffixes "${value}"; then
      printf -v "${variable_name}" '%s' "${value}"
      return 0
    fi
  done
}

install_prompt_rfc1918_cidr() {
  local variable_name="$1"
  local label="$2"
  local prefix="$3"
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
    if install_validate_rfc1918_cidr "${value}" "${prefix}" "${label}"; then
      printf -v "${variable_name}" '%s' "${value}"
      return 0
    fi
  done
}

install_prompt_choice() {
  local variable_name="$1"
  local label="$2"
  local choices="$3"
  local show_choices="${4:-true}"
  local current="${!variable_name:-}"
  local value choice index default_index=""
  local choice_values=()
  IFS='|' read -r -a choice_values <<<"${choices}"
  for index in "${!choice_values[@]}"; do
    if [[ "${show_choices}" == "true" ]]; then
      printf '  %d) %s\n' "$((index + 1))" "${choice_values[index]}"
    fi
    if [[ "${choice_values[index]}" == "${current}" ]]; then
      default_index="$((index + 1))"
    fi
  done
  while true; do
    if [[ -n "${default_index}" ]]; then
      printf '%s — select 1-%s [default %s: %s]: ' "${label}" \
        "${#choice_values[@]}" "${default_index}" "${current}"
    else
      printf '%s — select 1-%s: ' "${label}" "${#choice_values[@]}"
    fi
    read -r value
    value="${value:-${current}}"
    if [[ "${value}" =~ ^[0-9]+$ ]] \
      && [[ "${value}" -ge 1 ]] \
      && [[ "${value}" -le "${#choice_values[@]}" ]]; then
      value="${choice_values[value - 1]}"
    fi
    for choice in ${choices//|/ }; do
      if [[ "${value}" == "${choice}" ]]; then
        printf -v "${variable_name}" '%s' "${value}"
        return 0
      fi
    done
    printf 'Select a listed number or type one of: %s.\n' "${choices}"
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

install_use_known() {
  local variable_name="$1"
  local label="$2"
  local validator="$3"
  shift 3
  local current="${!variable_name:-}"
  if [[ -z "${current}" ]]; then
    return 1
  fi
  if "${validator}" "${current}" "$@"; then
    printf 'Using %s: %s\n' "${label}" "${current}"
    return 0
  fi
  return 1
}

install_require_deployment_name() {
  local variable_name="$1"
  local label="$2"
  install_use_known "${variable_name}" "${label}" \
    install_assert_deployment_name "${label}" \
    || install_prompt_deployment_name "${variable_name}" "${label}"
}

install_require_hostname() {
  local variable_name="$1"
  local label="$2"
  install_use_known "${variable_name}" "${label}" install_validate_hostname \
    || install_prompt_hostname "${variable_name}" "${label}"
}

install_require_dns1123() {
  local variable_name="$1"
  local label="$2"
  install_use_known "${variable_name}" "${label}" \
    install_assert_dns1123 "${label}" \
    || install_prompt_dns1123 "${variable_name}" "${label}"
}

install_pick_listed_name() {
  local wanted="$1"
  local listed="$2"
  [[ -n "${wanted}" && -n "${listed}" ]] || return 1
  grep -Fxq "${wanted}" <<<"${listed}"
}

install_resolve_data_instance() {
  local variable_name="$1"
  local label="$2"
  local expected="$3"
  local listed="$4"
  local current="${!variable_name:-${expected}}"
  if install_pick_listed_name "${current}" "${listed}"; then
    printf -v "${variable_name}" '%s' "${current}"
    printf 'Using %s: %s\n' "${label}" "${current}"
    return 0
  fi
  if [[ "${current}" != "${expected}" ]] \
    && install_pick_listed_name "${expected}" "${listed}"; then
    printf -v "${variable_name}" '%s' "${expected}"
    printf 'Using %s: %s\n' "${label}" "${expected}"
    return 0
  fi
  printf -v "${variable_name}" '%s' "${current}"
  install_require_dns1123 "${variable_name}" "${label}"
}

install_wait_for_condition() {
  local description="$1"
  local timeout_seconds="$2"
  local interval_seconds="$3"
  local check_fn="$4"
  local status_fn="${5:-}"
  local elapsed=0

  if "${check_fn}"; then
    printf '[install] %s is ready\n' "${description}"
    return 0
  fi
  printf '[install] waiting for %s (timeout %ss, every %ss)\n' \
    "${description}" "${timeout_seconds}" "${interval_seconds}"
  while (( elapsed < timeout_seconds )); do
    if [[ "${interval_seconds}" -gt 0 ]]; then
      sleep "${interval_seconds}"
    fi
    elapsed=$((elapsed + interval_seconds))
    if [[ "${interval_seconds}" -le 0 ]]; then
      elapsed="${timeout_seconds}"
    fi
    if [[ -n "${status_fn}" ]]; then
      printf '[install] %s: %s\n' "${description}" "$("${status_fn}")"
    fi
    if "${check_fn}"; then
      printf '[install] %s is ready\n' "${description}"
      return 0
    fi
  done
  printf '[install] timed out waiting for %s\n' "${description}" >&2
  return 1
}

install_gke_is_running() {
  [[ "${1:-}" == "RUNNING" ]]
}

install_gke_cluster_status() {
  local project region
  project="$(install_bootstrap_output project_id)" || return 1
  region="$(install_bootstrap_output region)" || return 1
  gcloud container clusters describe "${INFRA_DEPLOY_NAME}-gke" \
    --project="${project}" --region="${region}" \
    --format='value(status)' 2>/dev/null || true
}

install_gke_running_now() {
  install_gke_is_running "$(install_gke_cluster_status)"
}

install_ssl_cert_is_ready() {
  local status="${1:-}"
  local domain_status="${2:-}"
  [[ "${status}" == "ACTIVE" && "${domain_status}" != "FAILED_NOT_VISIBLE" ]]
}

install_query_ssl_cert_state() {
  local project="${1:-}"
  local domain="${2:-${DOMAIN_NAME:-}}"
  [[ -n "${project}" && -n "${domain}" ]] || return 1
  gcloud compute ssl-certificates list --project="${project}" --format=json \
    2>/dev/null \
    | jq -r --arg domain "${domain}" '
        .[]
        | select((.type // "" | ascii_upcase) == "MANAGED")
        | select((.managed.domains // []) | index($domain) != null)
        | "\(.managed.status // "")\t\((.managed.domainStatus // {})[$domain] // "")"
      ' \
    | head -n 1
}

install_ssl_cert_state_text() {
  local project state
  project="$(install_bootstrap_output project_id)" || {
    printf 'unknown'
    return 0
  }
  state="$(install_query_ssl_cert_state "${project}" "${DOMAIN_NAME}")" || true
  if [[ -z "${state}" ]]; then
    printf 'no managed certificate yet'
    return 0
  fi
  printf '%s domain=%s' "${state%%$'\t'*}" "${state#*$'\t'}"
}

install_ssl_cert_ready_now() {
  local project state status domain_status
  project="$(install_bootstrap_output project_id)" || return 1
  state="$(install_query_ssl_cert_state "${project}" "${DOMAIN_NAME}")" || return 1
  [[ -n "${state}" ]] || return 1
  status="${state%%$'\t'*}"
  domain_status="${state#*$'\t'}"
  install_ssl_cert_is_ready "${status}" "${domain_status}"
}

install_wait_for_gke_cluster() {
  if install_wait_for_condition \
    "GKE cluster ${INFRA_DEPLOY_NAME}-gke RUNNING" \
    "${INSTALL_GKE_WAIT_SECONDS}" \
    "${INSTALL_POLL_SECONDS}" \
    install_gke_running_now; then
    return 0
  fi
  install_die \
    "GKE cluster ${INFRA_DEPLOY_NAME}-gke is not RUNNING; rerun this step after the first infra deploy finishes"
}

install_wait_for_managed_certificate() {
  local reply
  if install_ssl_cert_ready_now; then
    printf 'Using managed certificate for %s: ACTIVE\n' "${DOMAIN_NAME}"
    return 0
  fi
  printf '[install] current certificate: %s\n' "$(install_ssl_cert_state_text)"
  while true; do
    if install_wait_for_condition \
      "managed certificate for ${DOMAIN_NAME}" \
      "${INSTALL_CERT_WAIT_SECONDS}" \
      "${INSTALL_POLL_SECONDS}" \
      install_ssl_cert_ready_now \
      install_ssl_cert_state_text; then
      return 0
    fi
    printf 'Certificate is not ACTIVE. Type skip to continue without HTTPS, or wait to keep polling: '
    read -r reply
    case "${reply}" in
      skip)
        printf '[install] WARNING: HTTPS will fail until the managed certificate is ACTIVE\n'
        return 1
        ;;
      wait|'')
        ;;
      *)
        printf 'Type skip or wait.\n'
        ;;
    esac
  done
}

install_http_ok() {
  local url="$1"
  curl --connect-timeout "${INSTALL_CURL_CONNECT_TIMEOUT:-10}" \
    --max-time "${INSTALL_CURL_MAX_TIME:-30}" \
    -fsS -o /dev/null "${url}"
}

install_public_https_ready() {
  local domain="${1:-${DOMAIN_NAME:-}}"
  [[ -n "${domain}" ]] || return 1
  install_http_ok "https://${domain}/healthz" \
    || install_http_ok "https://${domain}/dashboard/login"
}

install_wait_for_public_https() {
  local reply
  if install_public_https_ready; then
    printf 'Using public HTTPS: https://%s\n' "${DOMAIN_NAME}"
    return 0
  fi
  printf '[install] HTTPS is not ready at https://%s; waiting for the managed certificate\n' \
    "${DOMAIN_NAME}"
  install_wait_for_managed_certificate || true
  while ! install_public_https_ready; do
    printf 'https://%s is not serving HTTPS yet.\n' "${DOMAIN_NAME}"
    printf "Type 'retry' after the certificate is Active, or Ctrl-C to abort: "
    read -r reply
    if [[ "${reply}" == "retry" ]]; then
      install_wait_for_managed_certificate || true
    fi
  done
}

install_load_generated_defaults() {
  local env_file="${GENERATED_ENV}"
  local key value loaded=0

  [[ -f "${env_file}" ]] || return 0
  while IFS= read -r line || [[ -n "${line}" ]]; do
    case "${line}" in
      ''|\#*) continue ;;
      *=*) ;;
      *) continue ;;
    esac
    key="${line%%=*}"
    value="${line#*=}"
    [[ -n "${value}" ]] || continue
    [[ "${value}" == '{{.Secrets.'* ]] && continue
    case "${key}" in
      DEPLOY_NAME)
        INFRA_DEPLOY_NAME="${INFRA_DEPLOY_NAME:-${value}}"
        loaded=1
        ;;
      GATEWAY_DISTR_DEPLOYMENT_NAME)
        GATEWAY_DEPLOY_NAME="${GATEWAY_DEPLOY_NAME:-${value}}"
        loaded=1
        ;;
      DOMAIN_NAME|DNS_ZONE_NAME|CLOUDSQL_INSTANCE|REDIS_INSTANCE|VPC_CIDR|DATADOG_ENABLED|GATEWAY_CHART_VERSION|GATEWAY_ROUTE_ALLOWED_HOST_SUFFIXES)
        if [[ -z "${!key:-}" ]]; then
          printf -v "${key}" '%s' "${value}"
          loaded=1
        fi
        ;;
    esac
  done <"${env_file}"
  if [[ "${loaded}" -eq 1 ]]; then
    printf 'Loaded install defaults from %s\n' "${env_file}"
  fi
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
      DISTR_TOKEN=*)
        printf 'DISTR_TOKEN={{.Secrets.DISTR_TOKEN}}\n'
        ;;
      DD_API_KEY=*)
        if [[ "${DATADOG_ENABLED}" == "true" ]]; then
          printf 'DD_API_KEY={{.Secrets.DD_API_KEY}}\n'
        else
          printf 'DD_API_KEY=\n'
        fi
        ;;
      DD_APP_KEY=*)
        if [[ "${DATADOG_ENABLED}" == "true" ]]; then
          printf 'DD_APP_KEY={{.Secrets.DD_APP_KEY}}\n'
        else
          printf 'DD_APP_KEY=\n'
        fi
        ;;
      DASHBOARD_BOOTSTRAP_PASSWORD=*)
        printf 'DASHBOARD_BOOTSTRAP_PASSWORD={{.Secrets.%s}}\n' \
          "${DASHBOARD_BOOTSTRAP_SECRET_NAME}"
        ;;
      DASHBOARD_OIDC_CLIENT_SECRET=*)
        if [[ "${DASHBOARD_OIDC_ENABLED}" == "true" ]]; then
          printf 'DASHBOARD_OIDC_CLIENT_SECRET={{.Secrets.%s}}\n' \
            "${DASHBOARD_OIDC_SECRET_NAME}"
        else
          printf 'DASHBOARD_OIDC_CLIENT_SECRET=\n'
        fi
        ;;
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
      DATADOG_SITE=*) printf 'DATADOG_SITE=%s\n' "${DATADOG_SITE}" ;;
      DATADOG_ENV=*) printf 'DATADOG_ENV=%s\n' "${GCP_PROJECT}" ;;
      DATADOG_GCP_CLOUD_METRICS_ENABLED=*)
        printf 'DATADOG_GCP_CLOUD_METRICS_ENABLED=%s\n' "${DATADOG_ENABLED}"
        ;;
      GATEWAY_ROUTE_ALLOWED_HOST_SUFFIXES=*)
        printf 'GATEWAY_ROUTE_ALLOWED_HOST_SUFFIXES=%s\n' \
          "${GATEWAY_ROUTE_ALLOWED_HOST_SUFFIXES}"
        ;;
      GATEWAY_CHART_VERSION=*)
        printf 'GATEWAY_CHART_VERSION=%s\n' "${GATEWAY_CHART_VERSION}"
        ;;
      GATEWAY_AUTO_DEPLOY=*)
        printf 'GATEWAY_AUTO_DEPLOY=%s\n' "${GATEWAY_AUTO_DEPLOY}"
        ;;
      GATEWAY_WEBHOOK_URL=*)
        printf 'GATEWAY_WEBHOOK_URL=%s\n' "${GATEWAY_WEBHOOK_URL}"
        ;;
      GATEWAY_WEBHOOK_SIGNING_SECRET=*)
        if [[ -n "${GATEWAY_WEBHOOK_URL}" ]]; then
          printf 'GATEWAY_WEBHOOK_SIGNING_SECRET={{.Secrets.%s}}\n' \
            "${GATEWAY_WEBHOOK_SECRET_NAME}"
        else
          printf 'GATEWAY_WEBHOOK_SIGNING_SECRET=\n'
        fi
        ;;
      DASHBOARD_BOOTSTRAP_ORG_NAME=*)
        printf 'DASHBOARD_BOOTSTRAP_ORG_NAME=%s\n' \
          "${DASHBOARD_BOOTSTRAP_ORG_NAME}"
        ;;
      DASHBOARD_BOOTSTRAP_FULL_NAME=*)
        printf 'DASHBOARD_BOOTSTRAP_FULL_NAME=%s\n' \
          "${DASHBOARD_BOOTSTRAP_FULL_NAME}"
        ;;
      DASHBOARD_OIDC_ENABLED=*)
        printf 'DASHBOARD_OIDC_ENABLED=%s\n' "${DASHBOARD_OIDC_ENABLED}"
        ;;
      DASHBOARD_OIDC_PROVIDER=*)
        printf 'DASHBOARD_OIDC_PROVIDER=%s\n' "${DASHBOARD_OIDC_PROVIDER}"
        ;;
      DASHBOARD_OIDC_ISSUER_URL=*)
        printf 'DASHBOARD_OIDC_ISSUER_URL=%s\n' "${DASHBOARD_OIDC_ISSUER_URL}"
        ;;
      DASHBOARD_OIDC_CLIENT_ID=*)
        printf 'DASHBOARD_OIDC_CLIENT_ID=%s\n' "${DASHBOARD_OIDC_CLIENT_ID}"
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
Before changing GCP, confirm all four ownership areas:

  Subconscious/Distr
    - The customer organization appears in the Distr Vendor portal under
      Licenses.
    - It is entitled to the GCP api-gateway-infra Docker Application, the
      api-gateway Helm Application, and every image used by those releases.
    - The customer admin can sign in to that organization and create a PAT.

  Google Cloud
    - Choose one existing ACTIVE production project with billing enabled.
    - The installer identity can enable APIs and administer IAM in
      that project, and administer the selected public Cloud DNS zone.
    - ADC client-quota billing defaults to that same production project.

  Network/DNS
    - Reserve a free production hostname in an existing public Cloud DNS zone.
    - Reserve a non-overlapping RFC1918 /24 for the bootstrap VM and a separate
      non-overlapping RFC1918 /16 for the platform. Confirm neither overlaps
      the customer network, VPN, peering, or another cloud environment.

  Capacity/operations
    - Confirm N4A CPU quota and capacity in us-east1-b and us-east1-c.
    - Identify at least one operator user or Google Group, Datadog ownership,
      and rollback/upgrade owners.

Do not proceed with guessed project, DNS, CIDR, or entitlement values. None of
the Google IDs above are passwords, but they must belong to the customer's
approved production boundary.
EOF
  install_wait_for_word 'Complete those checks before continuing.' ready
}

install_step_2() {
  install_header 2 'Install tools and authenticate'
  "${SCRIPT_DIR}/install-gcloud.sh"
  cat <<'EOF'
The next login opens Google authorization twice:
  1. `gcloud auth login` authenticates CLI commands as your human user.
  2. `gcloud auth application-default login` creates user ADC for Terraform in
     gcloud's standard per-user configuration outside this repository.

Use the customer-approved human account. Do not download a service-account JSON
key, copy the ADC file into this repository, or paste a Google credential into
Distr Hub. Revoke the user session after handoff when customer policy requires.
EOF
  "${SCRIPT_DIR}/setup-gcloud.sh"
  cat <<'EOF'

The existing production project is selected in step 3. ADC quota uses that
same project automatically; there is no second project selection.
EOF
}

install_step_3() {
  local reuse_existing=false review_generated=false
  install_header 3 'Apply the production foundation'
  install_archive_legacy_local_state
  if [[ -f "${BOOTSTRAP_DIR}/terraform.tfvars" ]] \
    && install_tfvars_is_legacy "${BOOTSTRAP_DIR}/terraform.tfvars"; then
    install_replace_legacy_tfvars
  fi

  if [[ -f "${BOOTSTRAP_DIR}/terraform.tfvars" ]] \
    && install_validate_tfvars >/dev/null 2>&1; then
    reuse_existing=true
    printf '\nA valid production-only terraform.tfvars already exists at:\n  %s\n' \
      "${BOOTSTRAP_DIR}/terraform.tfvars"
    install_prompt_bool reuse_existing \
      'Reuse this completed configuration and skip the questionnaire'
  fi

  if [[ "${reuse_existing}" != "true" ]]; then
    install_collect_bootstrap_tfvars
  fi

  terraform fmt "${BOOTSTRAP_DIR}/terraform.tfvars" >/dev/null
  install_validate_tfvars
  review_generated=false
  install_prompt_bool review_generated \
    'Optionally open the completed terraform.tfvars for review'
  if [[ "${review_generated}" == "true" ]]; then
    install_review_tfvars
    terraform fmt "${BOOTSTRAP_DIR}/terraform.tfvars" >/dev/null
    install_validate_tfvars
  fi
  cat <<EOF

Foundation configuration is complete and saved with mode 0600:
  ${BOOTSTRAP_DIR}/terraform.tfvars

It contains identifiers and configuration only. Never put passwords, PATs,
API keys, ADC, or JSON keys in this file. The installer will now initialize,
validate, plan, ask for the explicit apply confirmation, and apply Terraform.
EOF
  ORANGELINE_GCP_INSTALLER=1 "${SCRIPT_DIR}/bootstrap.sh"
}

install_step_4() {
  local secret_prefix enable_oidc enable_webhook zone_dns_name zone_visibility
  local bootstrap_subnet_cidr
  install_header 4 'Configure all Distr environment variables and Secrets'
  install_prompt_deployment_name INFRA_DEPLOY_NAME 'Infra Docker deployment name'
  install_prompt_deployment_name GATEWAY_DEPLOY_NAME 'Gateway deployment/namespace name'
  secret_prefix="$(install_secret_prefix "${GATEWAY_DEPLOY_NAME}")"
  DASHBOARD_BOOTSTRAP_SECRET_NAME="${secret_prefix}_GATEWAY_DASHBOARD_BOOTSTRAP_PASSWORD"
  DASHBOARD_OIDC_SECRET_NAME="${secret_prefix}_GATEWAY_DASHBOARD_OIDC_CLIENT_SECRET"
  GATEWAY_WEBHOOK_SECRET_NAME="${secret_prefix}_GATEWAY_WEBHOOK_SIGNING_SECRET"
  GCP_PROJECT="$(install_bootstrap_output project_id)"
  GCP_REGION="$(install_bootstrap_output region)"
  GCP_DNS_PROJECT_ID="$(install_bootstrap_output dns_project_id)"
  TF_STATE_BUCKET="$(install_bootstrap_output state_bucket)"
  install_prompt_hostname DOMAIN_NAME 'Production gateway hostname'
  install_prompt_value DNS_ZONE_NAME 'Cloud DNS managed-zone resource name'
  zone_dns_name="$(gcloud dns managed-zones describe "${DNS_ZONE_NAME}" \
    --project "${GCP_DNS_PROJECT_ID}" --format='value(dnsName)' 2>/dev/null)" \
    || install_die \
      "cannot read managed zone ${GCP_DNS_PROJECT_ID}/${DNS_ZONE_NAME}"
  zone_visibility="$(gcloud dns managed-zones describe "${DNS_ZONE_NAME}" \
    --project "${GCP_DNS_PROJECT_ID}" --format='value(visibility)' 2>/dev/null)" \
    || install_die \
      "cannot inspect managed zone ${GCP_DNS_PROJECT_ID}/${DNS_ZONE_NAME}"
  [[ "${zone_visibility}" == "public" ]] \
    || install_die "Cloud DNS zone must be public (got: ${zone_visibility})"
  zone_dns_name="${zone_dns_name%.}"
  if [[ "${DOMAIN_NAME}" != "${zone_dns_name}" \
    && "${DOMAIN_NAME}" != *."${zone_dns_name}" ]]; then
    install_die \
      "hostname ${DOMAIN_NAME} is not inside Cloud DNS zone ${zone_dns_name}"
  fi
  VPC_CIDR="${VPC_CIDR:-10.60.0.0/16}"
  install_prompt_rfc1918_cidr VPC_CIDR 'Production platform RFC1918 /16' 16
  bootstrap_subnet_cidr="$(install_tfvar_string bootstrap_subnet_cidr)"
  install_validate_rfc1918_cidr \
    "${bootstrap_subnet_cidr}" 24 'bootstrap_subnet_cidr from terraform.tfvars'
  install_validate_cidrs_do_not_overlap "${VPC_CIDR}" "${bootstrap_subnet_cidr}"
  cat <<'EOF'

Provider suffixes are the DNS hosts the gateway may call for external
inference, taken from the approved provider endpoint URLs. Enter host suffixes
only (for example api.baseten.co), comma-separated—no https://, paths, API
keys, wildcard *, or customer gateway hostname.
EOF
  install_prompt_provider_suffixes GATEWAY_ROUTE_ALLOWED_HOST_SUFFIXES \
    'Allowed external provider DNS suffixes'
  GATEWAY_CHART_VERSION="${GATEWAY_CHART_VERSION:-latest}"
  install_prompt_value GATEWAY_CHART_VERSION \
    'Approved gateway chart version (latest, nochange, or named release)'
  DATADOG_ENABLED="${DATADOG_ENABLED:-true}"
  install_prompt_bool DATADOG_ENABLED 'Enable Datadog'
  DATADOG_SITE="${DATADOG_SITE:-datadoghq.com}"
  if [[ "${DATADOG_ENABLED}" == "true" ]]; then
    install_prompt_value DATADOG_SITE \
      'Datadog site from the login URL (for example datadoghq.com or us5.datadoghq.com)'
  fi

  DASHBOARD_BOOTSTRAP_ORG_NAME="${DASHBOARD_BOOTSTRAP_ORG_NAME:-${GATEWAY_DEPLOY_NAME}}"
  DASHBOARD_BOOTSTRAP_FULL_NAME="${DASHBOARD_BOOTSTRAP_FULL_NAME:-Gateway Admin}"
  install_prompt_value DASHBOARD_BOOTSTRAP_ORG_NAME \
    'Initial dashboard organization display name'
  install_prompt_value DASHBOARD_BOOTSTRAP_FULL_NAME \
    'Initial dashboard administrator full name'

  enable_oidc="${DASHBOARD_OIDC_ENABLED:-false}"
  install_prompt_bool enable_oidc 'Configure Okta/Entra OIDC during day-0'
  DASHBOARD_OIDC_ENABLED="${enable_oidc}"
  DASHBOARD_OIDC_PROVIDER="${DASHBOARD_OIDC_PROVIDER:-generic}"
  DASHBOARD_OIDC_ISSUER_URL="${DASHBOARD_OIDC_ISSUER_URL:-}"
  DASHBOARD_OIDC_CLIENT_ID="${DASHBOARD_OIDC_CLIENT_ID:-}"
  if [[ "${DASHBOARD_OIDC_ENABLED}" == "true" ]]; then
    install_prompt_choice DASHBOARD_OIDC_PROVIDER \
      'OIDC provider' 'okta|entra|generic'
    install_prompt_https_url DASHBOARD_OIDC_ISSUER_URL \
      'OIDC issuer URL from the identity-provider application'
    install_prompt_value DASHBOARD_OIDC_CLIENT_ID \
      'OIDC application/client ID (not the secret)'
  fi

  GATEWAY_WEBHOOK_URL="${GATEWAY_WEBHOOK_URL:-}"
  enable_webhook=false
  install_prompt_bool enable_webhook 'Enable usage-event webhook delivery'
  if [[ "${enable_webhook}" == "true" ]]; then
    install_prompt_https_url GATEWAY_WEBHOOK_URL \
      'Approved usage-event receiver URL'
  else
    GATEWAY_WEBHOOK_URL=""
  fi
  GATEWAY_AUTO_DEPLOY=false
  install_render_gateway_env "${GENERATED_ENV}"
  GATEWAY_AUTO_DEPLOY=true
  install_render_gateway_env "${GENERATED_AUTO_DEPLOY_ENV}"
  GATEWAY_AUTO_DEPLOY=false
  install_hub_walkthrough
}

install_hub_walkthrough() {
  cat <<EOF
Inputs are complete. Paste identifiers only; do not paste a resolved secret.

  First-pass environment:
    ${GENERATED_ENV}
  Second-pass environment (step 7 only):
    ${GENERATED_AUTO_DEPLOY_ENV}

Hub 1/2: create the api-gateway-infra Docker application
--------------------------------------------------------
Create an api-gateway-infra Docker deployment named ${INFRA_DEPLOY_NAME}.
Paste the first-pass file, select the approved GCP runner release, keep
GATEWAY_AUTO_DEPLOY=false and DISTR_DRY_RUN=0, and save. Do not connect the
Docker target yet.
EOF
  install_wait_for_word 'Save the infra Docker deployment.' 'done'

  cat <<EOF

Hub 2/2: create Hub Secrets
---------------------------
Create these masked Secrets in the customer organization. Paste resolved
values only into Hub Secret fields, never into the env file or this terminal.

  DISTR_TOKEN (required)
  ${DASHBOARD_BOOTSTRAP_SECRET_NAME} (required for day-0)
EOF
  if [[ "${DATADOG_ENABLED}" == "true" ]]; then
    cat <<EOF
  DD_API_KEY and DD_APP_KEY (required because Datadog is enabled)
EOF
  fi
  if [[ "${DASHBOARD_OIDC_ENABLED}" == "true" ]]; then
    cat <<EOF
  ${DASHBOARD_OIDC_SECRET_NAME} (required because OIDC is enabled)
    Redirect URI: https://${DOMAIN_NAME}/dashboard/auth/oidc/callback
EOF
  fi
  if [[ -n "${GATEWAY_WEBHOOK_URL}" ]]; then
    cat <<EOF
  ${GATEWAY_WEBHOOK_SECRET_NAME} (required because webhooks are enabled)
EOF
  fi
  install_wait_for_word 'Create and save the Hub Secrets above.' 'done'

  cat <<'EOF'

Connect the Docker agent in the next installer step. Create the gateway Helm
application in step 6 after that first infra deploy succeeds and GKE exists.
EOF
}

install_step_5() {
  local docker_connect_url=""
  install_header 5 'Connect Docker and run the first infra deployment'
  install_require_deployment_name INFRA_DEPLOY_NAME 'Infra Docker deployment name'
  install_read_secret docker_connect_url \
    'Paste the Docker target https://app.distr.sh/api/v1/connect URL'
  install_validate_connect_url "${docker_connect_url}"
  printf '%s\n' "${docker_connect_url}" \
    | "${SCRIPT_DIR}/run-agent.sh" --stdin
  unset docker_connect_url
  cat <<'EOF'
The URL was read with terminal echo disabled, sent over stdin/IAP, and not
stored in a file or process argument.
EOF
  if install_gke_running_now; then
    printf 'Using GKE cluster %s-gke: RUNNING\n' "${INFRA_DEPLOY_NAME}"
  else
    cat <<EOF
In Distr Hub:
  1. Verify the Docker target reports connected/healthy.
  2. Open the api-gateway-infra deployment created in step 4.
  3. Confirm GATEWAY_AUTO_DEPLOY=false and DISTR_DRY_RUN=0.
  4. Trigger the first deployment and watch its logs.
  5. Do not continue until the run succeeds and the GKE cluster exists.
EOF
    install_wait_for_word \
      'Confirm the first infra deployment completed successfully.' 'done'
    install_wait_for_gke_cluster
  fi
}

install_step_6() {
  local hub_command=""
  install_header 6 'Create the gateway Helm app and connect Kubernetes'
  install_require_deployment_name INFRA_DEPLOY_NAME 'Infra Docker deployment name'
  install_require_deployment_name GATEWAY_DEPLOY_NAME 'Gateway deployment/namespace name'
  cat <<EOF
The first infra deploy succeeded and GKE exists. Create the api-gateway Helm
application now, then immediately copy its Kubernetes target connect command.
If this deployment already exists from an earlier run, open it and do not
create a second one.

In Distr Hub:
  1. Create an api-gateway Helm deployment using the entitled, approved chart
     release.
  2. Use ${GATEWAY_DEPLOY_NAME} for ALL THREE values: Kubernetes target name,
     namespace, and Helm release.
  3. Leave Helm values empty because the infra runner generates and owns them.
  4. Save the deployment, open its Kubernetes target connect action, and copy
     the COMPLETE one-time command beginning with:

  kubectl apply -n ${GATEWAY_DEPLOY_NAME} -f "https://app.distr.sh/api/v1/connect?..."

Treat the command as a password because its URL contains targetSecret. Paste it
only into the hidden prompt below, not into shell history, chat, or a ticket.
An empty gateway deployment before the target exists is expected to do nothing.
EOF
  install_read_secret hub_command 'Paste the complete Hub kubectl apply command'
  install_validate_hub_command "${hub_command}"
  install_validate_hub_namespace "${hub_command}" "${GATEWAY_DEPLOY_NAME}"
  printf '%s\n' "${hub_command}" \
    | "${SCRIPT_DIR}/connect-k8s-agent.sh" --stdin "${INFRA_DEPLOY_NAME}"
  unset hub_command
}

install_step_7() {
  install_header 7 'Run the second infra deployment'
  install_require_deployment_name INFRA_DEPLOY_NAME 'Infra Docker deployment name'
  install_require_hostname DOMAIN_NAME 'Production gateway hostname'
  cat <<EOF
In the api-gateway-infra Hub environment:
  1. Replace the Environment field with the complete second-pass file:
       ${GENERATED_AUTO_DEPLOY_ENV}
  2. Confirm the only rollout difference is GATEWAY_AUTO_DEPLOY=true.
  3. Trigger the second infra deployment.
The installer then waits for the Google-managed certificate to become Active
before opening the dashboard. Do not delete or recreate the certificate.
EOF
  if ! install_ssl_cert_ready_now; then
    install_wait_for_word \
      'Trigger the second infra deployment, then type done to start the certificate wait.' \
      'done'
  fi
  install_wait_for_managed_certificate || true
}

install_step_8() {
  local secret_prefix bootstrap_secret_name
  install_header 8 'Verify the dashboard and a test chat'
  install_require_deployment_name GATEWAY_DEPLOY_NAME \
    'Gateway deployment/namespace name'
  install_require_hostname DOMAIN_NAME 'Production gateway hostname'
  install_wait_for_public_https
  secret_prefix="$(install_secret_prefix "${GATEWAY_DEPLOY_NAME}")"
  bootstrap_secret_name="${secret_prefix}_GATEWAY_DASHBOARD_BOOTSTRAP_PASSWORD"
  cat <<EOF
Open:
  https://${DOMAIN_NAME}/dashboard

Sign in as admin using the password stored in the masked Hub Secret:
  ${bootstrap_secret_name}

Do not copy that password into this CLI. After login:
  1. Invite the required users before they attempt OIDC; SSO does not create
     open accounts automatically.
  2. In the dashboard provider/model configuration, add the approved temporary
     Subconscious-hosted or external provider endpoint.
  3. Get its base URL, model name, and API key from the provider owner. Paste
     the API key only into the dashboard's masked credential field—not the Hub
     environment, this terminal, git, chat, or a ticket.
  4. Create a gateway organization API key in the dashboard for clients; save
     it directly in the customer's password manager.
  5. Run one test chat and require a non-empty response. Stop on login, OIDC,
     provider, routing, or response errors.
EOF
  install_wait_for_word 'Confirm dashboard login and the test chat succeeded.' 'done'
}

install_step_9() {
  local run_smoke
  install_header 9 'Verify platform and secret readiness'
  cat <<'EOF'
The read-only smoke check verifies GKE, Cloud SQL, Redis, the public endpoint,
Secret Manager/ESO synchronization, fixed Kubernetes Secrets, Distr rollouts,
the managed certificate, and Datadog when enabled. It does not print secret
values. Running it is strongly recommended before handoff.
EOF
  printf 'Run the read-only platform smoke checks now? [Y/n]: '
  read -r run_smoke
  case "${run_smoke}" in
    ''|y|Y|yes|YES)
      install_require_deployment_name INFRA_DEPLOY_NAME 'Infra Docker deployment name'
      install_require_deployment_name GATEWAY_DEPLOY_NAME 'Gateway deployment/namespace name'
      install_require_hostname DOMAIN_NAME 'Production gateway hostname'
      DATADOG_ENABLED="${DATADOG_ENABLED:-true}"
      export DATADOG_ENABLED
      GCP_PROJECT="$(install_bootstrap_output project_id)"
      GCP_REGION="$(install_bootstrap_output region)"
      printf '\nCloud SQL instances in %s:\n' "${GCP_PROJECT}"
      gcloud sql instances list --project "${GCP_PROJECT}" \
        --format='table(name,region,databaseVersion,state)'
      printf '\nRedis instances in %s/%s:\n' "${GCP_PROJECT}" "${GCP_REGION}"
      gcloud redis instances list --project "${GCP_PROJECT}" \
        --region "${GCP_REGION}" --format='table(name,region,redisVersion,state)'
      CLOUDSQL_INSTANCE="${CLOUDSQL_INSTANCE:-${INFRA_DEPLOY_NAME}-postgres}"
      REDIS_INSTANCE="${REDIS_INSTANCE:-${INFRA_DEPLOY_NAME}-redis}"
      install_resolve_data_instance CLOUDSQL_INSTANCE 'Cloud SQL instance name' \
        "${INFRA_DEPLOY_NAME}-postgres" \
        "$(gcloud sql instances list --project "${GCP_PROJECT}" --format='value(name)')"
      install_resolve_data_instance REDIS_INSTANCE 'Redis instance name' \
        "${INFRA_DEPLOY_NAME}-redis" \
        "$(gcloud redis instances list --project "${GCP_PROJECT}" \
          --region "${GCP_REGION}" --format='value(name)')"
      "${SCRIPT_DIR}/smoke-checks.sh" \
        "${INFRA_DEPLOY_NAME}" \
        "${GATEWAY_DEPLOY_NAME}" \
        "${DOMAIN_NAME}" \
        "${CLOUDSQL_INSTANCE}" \
        "${REDIS_INSTANCE}"
      ;;
    *)
      printf '[install] WARNING: verification skipped; the install is not handoff-ready\n'
      printf '[install] run scripts/smoke-checks.sh before production acceptance\n'
      ;;
  esac
}

install_step_10() {
  install_header 10 'Record handoff and ownership'
  cat <<'EOF'

Record the following in the customer's approved operations system. Record
identifiers, versions, owners, and links—never resolved passwords, PATs, API
keys, targetSecret URLs, ADC, or service-account JSON.

  - Production project ID/number, DNS project/zone/hostname/static IP, region,
    zones, bootstrap /24, platform /16, and Terraform state bucket.
  - Distr infra/gateway deployment and target names plus pinned Application
    versions/image digests.
  - GKE version/release channel, Cloud SQL and Redis instance names.
  - Operator groups, IAM reviewers, billing owner, DNS owner, and
    incident escalation path.
  - Datadog organization/site, integration status, dashboard/monitor links,
    and key rotation owner. Record secret NAMES only.
  - Successful smoke/test-chat evidence, rollback owner, upgrade window,
    backup/restore owner, and secret/PAT rotation dates.

The production install is handoff-ready only after step 9 passes and every
owner accepts their responsibility.
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
  install_load_generated_defaults
  printf '\nSubconscious Inference System - production GCP installer\n'
  printf 'Starting at step %s. Hub/application secrets are never stored locally.\n' \
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
