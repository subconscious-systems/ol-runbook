#!/usr/bin/env bash
# Bootstrap the production foundation in an existing GCP project.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TF_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
PLAN_FILE="${TF_DIR}/.bootstrap.tfplan"
VAR_FILE="${TF_DIR}/terraform.tfvars"
ASSUME_YES=0

usage() {
  cat >&2 <<'EOF'
usage: bootstrap.sh [--yes]

Plans and applies the production bootstrap foundation in an existing project, migrates the
first local state into the versioned GCS bucket, verifies the foundation, and
repairs the host. Without --yes, type the production project ID before apply.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --yes) ASSUME_YES=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage; exit 2 ;;
  esac
done

for tool in gcloud terraform jq; do
  command -v "${tool}" >/dev/null 2>&1 || {
    printf 'ERROR: %s is required\n' "${tool}" >&2
    exit 1
  }
done
[[ -f "${VAR_FILE}" ]] || {
  printf 'ERROR: copy terraform.tfvars.example to terraform.tfvars and edit it first\n' >&2
  exit 1
}

legacy_environment_label='sand''box'
if grep -Eq "^[[:space:]]*(enabled_environments|production_project_id|${legacy_environment_label}_project_id)[[:space:]]*=" "${VAR_FILE}"; then
  printf 'ERROR: legacy multi-environment values found; recreate terraform.tfvars from the current example\n' >&2
  exit 1
fi

gcloud auth application-default print-access-token >/dev/null
if [[ -f "${TF_DIR}/backend.tf" ]]; then
  [[ -f "${TF_DIR}/.backend.hcl" ]] || {
    printf 'ERROR: backend.tf exists without .backend.hcl\n' >&2
    exit 1
  }
  terraform -chdir="${TF_DIR}" init -input=false -reconfigure -backend-config=.backend.hcl
else
  terraform -chdir="${TF_DIR}" init -input=false
fi

if terraform -chdir="${TF_DIR}" state list 2>/dev/null | grep -Eq '^google_project\.environment\["'; then
  printf 'ERROR: legacy multi-environment state detected; do not apply the production-only stack to it\n' >&2
  exit 1
fi

terraform -chdir="${TF_DIR}" fmt -check -recursive
terraform -chdir="${TF_DIR}" validate
terraform -chdir="${TF_DIR}" plan -input=false -var-file="${VAR_FILE}" -out="${PLAN_FILE}"

DESTRUCTIVE_ADDRESSES="$(terraform -chdir="${TF_DIR}" show -json "${PLAN_FILE}" \
  | jq -r '
      .resource_changes[]?
      | select(.change.actions | index("delete"))
      | .address
    ')"
if [[ -n "${DESTRUCTIVE_ADDRESSES}" ]]; then
  printf 'ERROR: bootstrap refuses a plan containing resource deletions:\n%s\n' \
    "${DESTRUCTIVE_ADDRESSES}" >&2
  printf 'Resolve or isolate the previous Terraform state before applying.\n' >&2
  rm -f "${PLAN_FILE}"
  exit 1
fi

PROJECT_ID="$(terraform -chdir="${TF_DIR}" show -json "${PLAN_FILE}" | jq -er '
  .planned_values.outputs.project_id.value
')"
terraform -chdir="${TF_DIR}" show "${PLAN_FILE}"
if [[ "${ASSUME_YES}" -ne 1 ]]; then
  [[ -t 0 ]] || {
    printf 'ERROR: bootstrap requires an interactive terminal or --yes\n' >&2
    exit 1
  }
  printf 'Type the production project ID (%s) to apply this plan: ' "${PROJECT_ID}"
  read -r confirmation
  [[ "${confirmation}" == "${PROJECT_ID}" ]] || {
    printf '[bootstrap] cancelled\n'
    exit 1
  }
fi

terraform -chdir="${TF_DIR}" apply -input=false "${PLAN_FILE}"
rm -f "${PLAN_FILE}"
if [[ ! -f "${TF_DIR}/backend.tf" ]]; then
  "${SCRIPT_DIR}/migrate-state.sh" --yes
fi
"${SCRIPT_DIR}/preflight.sh"
"${SCRIPT_DIR}/repair-host.sh"

cat <<'EOF'

== GCP Docker agent host ready ==

Next:
  1. Create the api-gateway-infra Docker deployment in Distr Hub and paste the
     GCP environment from ../sample-gateway-infra.env.
  2. Keep GATEWAY_AUTO_DEPLOY=false for the first infra deployment.
  3. Copy the Docker target connect URL and run:
       ./scripts/run-agent.sh 'https://app.distr.sh/api/v1/connect?targetId=…&targetSecret=…'
  4. After GKE exists, create the gateway Helm deployment and connect its agent:
       ./scripts/connect-k8s-agent.sh <INFRA_DEPLOY_NAME> \
         'kubectl apply -n <GATEWAY_DISTR_DEPLOYMENT_NAME> -f "https://app.distr.sh/api/v1/connect?…"'
  5. Set GATEWAY_AUTO_DEPLOY=true and trigger the second infra deployment.
EOF
