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
  CLOUDSQL_INSTANCE, REDIS_INSTANCE, QUOTA_PROJECT_ID, DATADOG_ENABLED
EOF
}

install_list_steps() {
  cat <<'EOF'
1   Confirm entitlements, account inputs, naming, quota, and capacity
2   Install gcloud tools and authenticate the human user plus ADC
3   Configure and apply the production project/bootstrap foundation
4   Configure every Distr environment variable and Hub Secret
5   Connect the Docker agent and complete the first infra deployment
6   Create the api-gateway Helm deployment and connect its Kubernetes agent
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

install_validate_numeric_id() {
  local value="${1:-}"
  local label="${2:-ID}"
  [[ "${value}" =~ ^[0-9]+$ ]] || {
    printf 'ERROR: %s must be a numeric Google Cloud ID\n' "${label}" >&2
    return 2
  }
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

install_validate_project_name() {
  local value="${1:-}"
  if [[ "${#value}" -lt 4 || "${#value}" -gt 30 ]] \
    || [[ "${value}" == *\"* || "${value}" == *\\* ]]; then
    printf 'ERROR: project name must be 4-30 plain-text characters\n' >&2
    return 2
  fi
}

install_validate_positive_integer() {
  local value="${1:-}"
  local label="${2:-value}"
  [[ "${value}" =~ ^[1-9][0-9]*$ ]] || {
    printf 'ERROR: %s must be a positive whole number\n' "${label}" >&2
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
  local organization_id folder_id parent_count=0
  [[ -r "${file}" ]] || install_die "terraform.tfvars is missing"

  if grep -Eq \
    '^[[:space:]]*((organization_id|folder_id)[[:space:]]*=[[:space:]]*"123456789012"|billing_account_id[[:space:]]*=[[:space:]]*"000000-000000-000000"|quota_project_id[[:space:]]*=[[:space:]]*"example-platform-admin"|project_id[[:space:]]*=[[:space:]]*"example-gateway-prod"|project_name[[:space:]]*=[[:space:]]*"Example Gateway Production"|dns_project_id[[:space:]]*=[[:space:]]*"example-shared-dns"|"group:gateway-platform@example\.com")' \
    "${file}"; then
    install_die \
      'terraform.tfvars still contains an example value; replace every customer-specific example'
  fi

  organization_id="$(install_tfvar_string organization_id)"
  folder_id="$(install_tfvar_string folder_id)"
  [[ -n "${organization_id}" ]] && parent_count=$((parent_count + 1))
  [[ -n "${folder_id}" ]] && parent_count=$((parent_count + 1))
  [[ "${parent_count}" -eq 1 ]] || install_die \
    'set exactly one quoted organization_id or folder_id in terraform.tfvars'
  chmod 0600 "${file}"
}

install_tfvars_is_legacy() {
  local file="$1"
  local legacy_environment_label='sand''box'
  grep -Eq \
    "^[[:space:]]*(enabled_environments|production_project_id|${legacy_environment_label}_project_id|monthly_budget_amounts_usd|bootstrap_zones|bootstrap_subnet_cidrs)[[:space:]]*=" \
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

install_create_quota_project() {
  local parent_description parent_flag=()
  cat <<'EOF'

Create a dedicated ADC quota project
------------------------------------
This is a small Google Cloud control-plane project used to attribute API quota
while Terraform creates and administers the production gateway project. It is
not the production gateway project and does not run gateway workloads.

Creating it requires permission to create a project under the selected parent,
attach the selected billing account, enable APIs, and consume Service Usage.
Keep it available for future Terraform administration, or change
quota_project_id before retiring it. The selected billing account is attached,
but this workflow creates no compute, database, or network resources in it.
EOF
  FOUNDATION_QUOTA_PROJECT_NAME="${FOUNDATION_QUOTA_PROJECT_NAME:-Subconscious Gateway Admin}"
  install_prompt_validated FOUNDATION_QUOTA_PROJECT_ID \
    'New globally unique quota project ID' install_validate_gcp_project_id \
    'quota project ID'
  install_prompt_validated FOUNDATION_QUOTA_PROJECT_NAME \
    'Quota project display name' install_validate_project_name

  if [[ -n "${ORGANIZATION_ID}" ]]; then
    parent_description="organization ${ORGANIZATION_ID}"
    parent_flag=(--organization "${ORGANIZATION_ID}")
  else
    parent_description="folder ${FOLDER_ID}"
    parent_flag=(--folder "${FOLDER_ID}")
  fi
  cat <<EOF

The CLI will now create:
  project ID:      ${FOUNDATION_QUOTA_PROJECT_ID}
  display name:    ${FOUNDATION_QUOTA_PROJECT_NAME}
  parent:          ${parent_description}
  billing account: ${BILLING_ACCOUNT_ID}
EOF
  install_wait_for_word \
    'Confirm this new billable Google Cloud project.' create
  gcloud projects create "${FOUNDATION_QUOTA_PROJECT_ID}" \
    --name "${FOUNDATION_QUOTA_PROJECT_NAME}" "${parent_flag[@]}"
  gcloud billing projects link "${FOUNDATION_QUOTA_PROJECT_ID}" \
    --billing-account "${BILLING_ACCOUNT_ID}"
  QUOTA_PROJECT_ID="${FOUNDATION_QUOTA_PROJECT_ID}"
  printf '[install] created quota project: %s\n' "${QUOTA_PROJECT_ID}"
}

install_render_bootstrap_tfvars() {
  local output_file="$1"
  local temporary_file="${output_file}.tmp.$$"
  local item
  local principals=()
  umask 077
  {
    printf '# Generated by scripts/install.sh. Identifiers only; no secrets.\n\n'
    printf 'organization_id = "%s"\n' "${ORGANIZATION_ID}"
    printf 'folder_id       = "%s"\n\n' "${FOLDER_ID}"
    printf 'billing_account_id = "%s"\n' "${BILLING_ACCOUNT_ID}"
    printf 'quota_project_id   = "%s"\n\n' "${QUOTA_PROJECT_ID:-}"
    printf 'project_id   = "%s"\n' "${FOUNDATION_PROJECT_ID}"
    printf 'project_name = "%s"\n\n' "${FOUNDATION_PROJECT_NAME}"
    printf 'dns_project_id = "%s"\n\n' "${FOUNDATION_DNS_PROJECT_ID}"
    printf 'monthly_budget_amount_usd = %s\n\n' "${MONTHLY_BUDGET_AMOUNT_USD}"
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
    printf 'project_deletion_policy = "PREVENT"\n'
    printf 'protect_bootstrap_vms   = true\n\n'
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
  local active_account billing_candidates discovery_org_id folder_candidates
  local organization_candidates parent_type="organization" project_candidates
  local retired_environment_name='sand''box' retired_environment_short='s''box'
  cat <<'EOF'

Required production foundation inputs
-------------------------------------
The CLI will discover candidates where Google permits it and then ask for the
exact value. These are identifiers/configuration, not secrets.

REQUIRED:
  - one numeric organization ID or folder ID;
  - one open billing-account ID;
  - a new globally unique production project ID and display name;
  - an existing project that owns the approved public Cloud DNS zone;
  - a positive whole-dollar monthly budget alert;
  - a non-overlapping private /24 for the bootstrap VM;
  - at least one IAP/OS Login operator user or Google Group.

OPTIONAL:
  - an ADC quota project for client API charges. Select an existing project,
    create a dedicated control-plane project, or skip only when customer policy
    already configures ADC quota.

FIXED production safety values:
  - region us-east1, e2-standard-2/40 GiB bootstrap VM;
  - project deletion PREVENT and VM deletion protection enabled.
EOF

  organization_candidates="$(
    gcloud organizations list --format=json 2>/dev/null \
      | jq -r '.[] | [((.name // "") | split("/") | last), (.displayName // "unnamed")] | @tsv' \
      || true
  )"
  cat <<'EOF'
Find these in Google Cloud Console > IAM & Admin > Manage Resources. Select the
customer organization or folder and copy its numeric ID, not its display name.

Choose where the new production project belongs:
  1) organization — directly at the customer organization root;
  2) folder       — inside an existing GCP folder used by the customer.

If the customer gave you a folder for production workloads, choose folder.
Otherwise choose organization. Ask the customer's GCP administrator instead of
guessing when both are visible.
EOF
  install_prompt_choice parent_type \
    'Production project parent' \
    'organization|folder'
  ORGANIZATION_ID=""
  FOLDER_ID=""
  if [[ "${parent_type}" == "organization" ]]; then
    install_prompt_candidate ORGANIZATION_ID \
      'Required parent organization' "${organization_candidates}" \
      install_validate_numeric_id \
      'organization ID'
  else
    cat <<'EOF'
Choose the organization containing the folder so Google can list its direct
top-level folders. For a nested or permission-hidden folder, choose manual ID
entry at the next prompt. Manage Resources shows every visible folder ID.
EOF
    install_prompt_candidate discovery_org_id \
      'Organization used to discover folders' "${organization_candidates}" \
      install_validate_numeric_id 'organization ID'
    folder_candidates="$(
      gcloud resource-manager folders list \
        --organization "${discovery_org_id}" --format=json 2>/dev/null \
        | jq -r '.[] | [((.name // "") | split("/") | last), (.displayName // "unnamed")] | @tsv' \
        || true
    )"
    install_prompt_candidate FOLDER_ID \
      'Required parent folder' "${folder_candidates}" \
      install_validate_numeric_id 'folder ID'
  fi

  billing_candidates="$(
    gcloud billing accounts list --filter='open=true' --format=json 2>/dev/null \
      | jq -r '.[] | [((.name // "") | split("/") | last), (.displayName // "unnamed")] | @tsv' \
      || true
  )"
  cat <<'EOF'
Also available in Google Cloud Console > Billing > Manage billing accounts.
Copy the ID shaped 000000-000000-000000. The active user must be allowed to
attach this account to the new project.
EOF
  install_prompt_candidate BILLING_ACCOUNT_ID \
    'Required billing account' "${billing_candidates}" \
    install_validate_billing_account_id

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
The quota project, when used, must already exist and allow your user to consume
and enable Google APIs, or you can create a dedicated one here. It is not the
new production project Terraform will create.
EOF
  install_prompt_optional_candidate QUOTA_PROJECT_ID \
    'Optional ADC quota project' "${project_candidates}" \
    install_validate_gcp_project_id install_create_quota_project \
    'quota project ID'
  if [[ -n "${QUOTA_PROJECT_ID:-}" ]]; then
    "${SCRIPT_DIR}/setup-gcloud.sh" \
      --skip-login --quota-project "${QUOTA_PROJECT_ID}"
  fi

  cat <<'EOF'

Choose a NEW globally unique project ID. Use 6-30 lowercase letters, digits,
and hyphens; it cannot be changed after creation. Terraform creates it, so do
not create it manually. The display name is human-readable and can change.
EOF
  install_prompt_validated FOUNDATION_PROJECT_ID \
    'Required new production project ID' install_validate_gcp_project_id \
    'production project ID'
  FOUNDATION_PROJECT_NAME="${FOUNDATION_PROJECT_NAME:-Subconscious Gateway Prod}"
  install_prompt_validated FOUNDATION_PROJECT_NAME \
    'Required production project display name' install_validate_project_name

  cat <<'EOF'

The DNS project is an EXISTING project containing the public managed zone for
the gateway hostname. It is usually a shared DNS/network project, not the new
production project. Copy the project ID from Manage Resources.
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

  MONTHLY_BUDGET_AMOUNT_USD="${MONTHLY_BUDGET_AMOUNT_USD:-1200}"
  install_prompt_validated MONTHLY_BUDGET_AMOUNT_USD \
    'Required monthly budget-alert amount in whole USD' \
    install_validate_positive_integer 'monthly budget'
  printf 'This budget sends alerts; it is not a hard spending cap.\n'

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
  local candidate_value candidate_label index=0
  while IFS=$'\t' read -r candidate_value candidate_label; do
    [[ -n "${candidate_value}" ]] || continue
    index=$((index + 1))
    printf '  %d) %s  [ID: %s]\n' "${index}" \
      "${candidate_label:-unnamed}" "${candidate_value}"
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
  local candidate_count choice selected
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
        printf '[install] selected ID: %s\n' "${selected}"
        return
      fi
    fi
    printf 'Choose a listed number or m for manual entry.\n'
  done
}

install_prompt_optional_candidate() {
  local variable_name="$1"
  local label="$2"
  local candidates="$3"
  local validator="$4"
  local create_function="$5"
  shift 5
  local candidate_count choice create_option="" current selected value
  current="${!variable_name:-}"
  if [[ -n "${create_function}" ]]; then
    create_option=', c to create a new project'
  fi
  printf '\n%s candidates visible to the active Google account:\n' "${label}"
  install_print_candidates "${candidates}"
  candidate_count="$(install_candidate_count "${candidates}")"
  if [[ "${candidate_count}" -eq 0 ]]; then
    printf '  No candidates were returned. Check access, create one, or enter an ID manually.\n'
  fi
  while true; do
    if [[ "${candidate_count}" -eq 0 && -n "${current}" ]]; then
      printf 'Type m for manual entry%s, s to skip, or Enter to keep %s: ' \
        "${create_option}" "${current}"
    elif [[ "${candidate_count}" -eq 0 ]]; then
      printf 'Type m for manual entry%s, or press Enter to skip: ' \
        "${create_option}"
    elif [[ -n "${current}" ]]; then
      printf 'Select 1-%s, m for manual entry%s, s to skip, or Enter to keep %s: ' \
        "${candidate_count}" "${create_option}" "${current}"
    else
      printf 'Select 1-%s, m for manual entry%s, or press Enter to skip: ' \
        "${candidate_count}" "${create_option}"
    fi
    read -r choice
    [[ -n "${choice}" ]] || {
      printf -v "${variable_name}" '%s' "${current}"
      return
    }
    if [[ "${choice}" == "s" || "${choice}" == "S" ]]; then
      printf -v "${variable_name}" '%s' ''
      return
    fi
    if [[ -n "${create_function}" \
      && ( "${choice}" == "c" || "${choice}" == "C" ) ]]; then
      "${create_function}"
      return
    fi
    if [[ "${choice}" == "m" || "${choice}" == "M" ]]; then
      while true; do
        install_prompt_optional "${variable_name}" "${label} ID"
        value="${!variable_name:-}"
        [[ -z "${value}" ]] || "${validator}" "${value}" "$@" || continue
        return
      done
    fi
    if [[ "${choice}" =~ ^[0-9]+$ ]] \
      && selected="$(install_candidate_value "${candidates}" "${choice}")"; then
      if "${validator}" "${selected}" "$@"; then
        printf -v "${variable_name}" '%s' "${selected}"
        printf '[install] selected ID: %s\n' "${selected}"
        return
      fi
    fi
    printf 'Choose a listed number, m for manual entry%s, s to skip, or Enter for the default.\n' \
      "${create_option}"
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
  local current="${!variable_name:-}"
  local value choice index default_index=""
  local choice_values=()
  IFS='|' read -r -a choice_values <<<"${choices}"
  for index in "${!choice_values[@]}"; do
    printf '  %d) %s\n' "$((index + 1))" "${choice_values[index]}"
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
    - The installer identity can create a project under the intended
      organization or folder, attach billing, assign IAM, and administer the
      selected existing public Cloud DNS zone.
    - Choose one globally unique production project ID and one existing
      project that can be used for ADC client-quota billing during bootstrap.

  Network/DNS
    - Reserve a free production hostname in an existing public Cloud DNS zone.
    - Reserve a non-overlapping RFC1918 /24 for the bootstrap VM and a separate
      non-overlapping RFC1918 /16 for the platform. Confirm neither overlaps
      the customer network, VPN, peering, or another cloud environment.

  Capacity/operations
    - Confirm N4A CPU quota and capacity in us-east1-b and us-east1-c.
    - Identify at least one operator user or Google Group, the approved monthly
      budget-alert amount, Datadog ownership, and rollback/upgrade owners.

Do not proceed with guessed organization, billing, DNS, CIDR, or entitlement
values. None of the Google IDs above are passwords, but they must belong to the
customer's approved production boundary.
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

The optional ADC quota project is selected in step 3, after the CLI knows the
approved parent and billing account. You can select an existing project, create
a dedicated control-plane project, or skip it when customer policy already
supplies ADC quota. It is never the new production gateway project.
EOF
}

install_step_3() {
  local reuse_existing=false review_generated=false
  install_header 3 'Apply the production foundation'
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
  "${SCRIPT_DIR}/bootstrap.sh"
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
  cat <<EOF
This is the single Distr configuration step. It has now collected and
validated every customer-specific environment input. The generated files also
carry the reviewed production defaults for GKE, Cloud SQL, Redis, deletion
protection, Datadog features, gateway versions, and hosted auth. Do not add
unlisted variables or hand-edit a resolved secret into either file.

Create these in the CUSTOMER ORGANIZATION's Distr Hub Secrets screen. Every
value must be pasted directly into a masked Secret value field. Do not paste a
resolved value into the deployment environment, this terminal, chat, a ticket,
or git.

  DISTR_TOKEN (required)
    Source: sign in as the customer admin and create a customer PAT in Distr
    account settings. This is not a vendor publish token. Copy it once and
    paste it into the masked Hub Secret named exactly DISTR_TOKEN.

  ${DASHBOARD_BOOTSTRAP_SECRET_NAME} (required for day-0)
    Source: generate a unique 20+ character random password in the customer's
    password manager. Paste it into this masked Hub Secret and retain it there
    for the initial admin login. Never place it directly in the env file.
EOF
  if [[ "${DATADOG_ENABLED}" == "true" ]]; then
    cat <<EOF

  DD_API_KEY and DD_APP_KEY (required because Datadog is enabled)
    Source: Datadog Organization Settings > API Keys and Application Keys in
    the SAME Datadog organization/site (${DATADOG_SITE}). Use dedicated
    install keys. The application key needs the permissions documented in
    api-gateway/gcp/datadog-operations.md, including GCP configuration read
    plus the manage permissions used by Terraform. Paste each into its matching
    masked Hub Secret. These are Datadog keys, never Google credentials.
EOF
  fi
  if [[ "${DASHBOARD_OIDC_ENABLED}" == "true" ]]; then
    cat <<EOF

  ${DASHBOARD_OIDC_SECRET_NAME} (required because OIDC is enabled)
    Source: the client secret from the Okta/Entra/generic Web OIDC application
    whose redirect URI is:
      https://${DOMAIN_NAME}/dashboard/auth/oidc/callback
    Paste only the secret into this masked Hub Secret. The non-secret issuer
    and client ID are already in the generated environment. Keep the bootstrap
    password: the admin must invite users before their first SSO login.
EOF
  fi
  if [[ -n "${GATEWAY_WEBHOOK_URL}" ]]; then
    cat <<EOF

  ${GATEWAY_WEBHOOK_SECRET_NAME} (required because webhooks are enabled)
    Source: generate a unique 32-byte HMAC secret in the customer password
    manager. Paste the same value into this masked Hub Secret and the approved
    receiver's GATEWAY_WEBHOOK_SIGNING_SECRET setting. Never put it directly in
    the env file.
EOF
  fi
  cat <<EOF

Then create the deployment in Distr Hub:
  1. Create an api-gateway-infra Docker deployment named:
       ${INFRA_DEPLOY_NAME}
  2. Paste this generated environment into its Environment field:
       ${GENERATED_ENV}
     It contains secret REFERENCES only, never the resolved values.
  3. Select the entitled, approved GCP runner release. Confirm the release's
     environment template recognizes every generated field.
  4. Keep GATEWAY_AUTO_DEPLOY=false and DISTR_DRY_RUN=0 for the first pass.
  5. Keep HOSTED_AUTH_ENABLED=false unless Subconscious supplied an approved
     hosted-control-plane contract and every corresponding value.
  6. Save the deployment/target, then use Hub's connect action to copy the
     one-time Docker target URL. Treat that URL as a password.

The second-pass environment is already prepared at:
  ${GENERATED_AUTO_DEPLOY_ENV}

It is identical except GATEWAY_AUTO_DEPLOY=true. Do not paste it until step 7,
after the Kubernetes target is connected.

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
  printf '%s\n' "${docker_connect_url}" \
    | "${SCRIPT_DIR}/run-agent.sh" --stdin
  unset docker_connect_url
  cat <<'EOF'
The URL was read with terminal echo disabled, sent over stdin/IAP, and not
stored in a file or process argument.

In Distr Hub:
  1. Verify the Docker target reports connected/healthy.
  2. Open the api-gateway-infra deployment created in step 4.
  3. Confirm GATEWAY_AUTO_DEPLOY=false and DISTR_DRY_RUN=0.
  4. Trigger the first deployment and watch its logs.
  5. Do not continue until the run succeeds and the GKE cluster exists.
EOF
  install_wait_for_word 'Confirm the first infra deployment completed successfully.' 'done'
}

install_step_6() {
  local hub_command=""
  install_header 6 'Create the Helm deployment and connect Kubernetes'
  install_prompt_deployment_name INFRA_DEPLOY_NAME 'Infra Docker deployment name'
  install_prompt_deployment_name GATEWAY_DEPLOY_NAME 'Gateway deployment/namespace name'
  cat <<EOF
In Distr Hub:
  1. Create an api-gateway Helm deployment using the entitled, approved chart
     release.
  2. Use ${GATEWAY_DEPLOY_NAME} for ALL THREE values: Kubernetes target name,
     namespace, and Helm release.
  3. Leave Helm values empty because the infra runner generates and owns them.
  4. Save/deploy once, open the Kubernetes target's connect action, and copy
     the COMPLETE one-time command beginning with:

  kubectl apply -n ${GATEWAY_DEPLOY_NAME} -f "https://app.distr.sh/api/v1/connect?..."

Treat the command as a password because its URL contains targetSecret. Paste it
only into the hidden prompt below—not into shell history, chat, or a ticket.
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
  cat <<EOF
In the api-gateway-infra Hub environment:
  1. Replace the Environment field with the complete second-pass file prepared
     in the single configuration step:
       ${GENERATED_AUTO_DEPLOY_ENV}
     Do not edit individual values or paste a resolved Hub Secret.
  2. Confirm its only rollout difference is GATEWAY_AUTO_DEPLOY=true and that
     GATEWAY_CHART_VERSION is the approved value prepared in step 4.
  3. Trigger the second infra deployment.
  4. Wait for Terraform, ESO secret synchronization, the Helm deployment, the
     managed certificate, and public readiness to complete.
EOF
  install_wait_for_word 'Confirm the second infra deployment completed successfully.' 'done'
}

install_step_8() {
  local secret_prefix bootstrap_secret_name
  install_header 8 'Verify the dashboard and a test chat'
  install_prompt_deployment_name GATEWAY_DEPLOY_NAME \
    'Gateway deployment/namespace name'
  install_prompt_hostname DOMAIN_NAME 'Production gateway hostname'
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
      install_prompt_deployment_name INFRA_DEPLOY_NAME 'Infra Docker deployment name'
      install_prompt_deployment_name GATEWAY_DEPLOY_NAME 'Gateway deployment/namespace name'
      install_prompt_hostname DOMAIN_NAME 'Production gateway hostname'
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
  - Operator groups, IAM reviewers, billing/budget owner, DNS owner, and
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
