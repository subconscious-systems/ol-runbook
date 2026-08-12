#!/usr/bin/env bash
# Plan or apply the single production GCP bootstrap foundation.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TF_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
MODE="plan"
ASSUME_YES=0
PLAN_FILE=".bootstrap.tfplan"
VAR_FILE="${TF_DIR}/terraform.tfvars"

usage() {
  cat >&2 <<'EOF'
usage: bootstrap.sh [--plan [--var-file FILE]] [--apply [--yes]]

--plan creates the production foundation plan saved at .bootstrap.tfplan.
Review that plan before running --apply. --apply consumes the exact saved plan;
it never silently replans. Without --yes, type the production project ID to
confirm the target.

--var-file lets the guided installer supply generated JSON inputs without
creating or replacing terraform.tfvars. It is used only while planning.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --plan)
      MODE="plan"
      shift
      ;;
    --apply)
      MODE="apply"
      shift
      ;;
    --yes)
      ASSUME_YES=1
      shift
      ;;
    --var-file)
      [[ $# -ge 2 ]] || {
        usage
        exit 2
      }
      VAR_FILE="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      printf 'ERROR: unknown argument: %s\n' "$1" >&2
      usage
      exit 2
      ;;
  esac
done

if [[ "${ASSUME_YES}" -eq 1 && "${MODE}" != "apply" ]]; then
  printf 'ERROR: --yes is valid only with --apply\n' >&2
  exit 2
fi

for tool in gcloud terraform jq; do
  command -v "${tool}" >/dev/null 2>&1 || {
    printf 'ERROR: %s is required\n' "${tool}" >&2
    exit 1
  }
done

if [[ "${MODE}" == "plan" && ! -f "${VAR_FILE}" ]]; then
  printf 'ERROR: Terraform variable file does not exist: %s\n' "${VAR_FILE}" >&2
  exit 1
fi

legacy_environment_label='sand''box'
if [[ "${MODE}" == "plan" ]] && grep -Eq \
  "^[[:space:]]*(enabled_environments|production_project_id|${legacy_environment_label}_project_id)[[:space:]]*=" \
  "${VAR_FILE}"; then
  cat >&2 <<'EOF'
ERROR: legacy multi-environment values found in terraform.tfvars.
Back up that file outside the repository, recreate it from the current
terraform.tfvars.example, and enter only the approved production project.
EOF
  exit 1
fi

gcloud auth application-default print-access-token >/dev/null
terraform -chdir="${TF_DIR}" init -input=false

if terraform -chdir="${TF_DIR}" state list 2>/dev/null \
  | grep -Eq '^google_project\.environment\["'; then
  cat >&2 <<'EOF'
ERROR: legacy multi-environment bootstrap state detected.
Do not apply the production-only stack to that state. Use the prior runbook
revision to destroy/archive the old resources, then initialize a clean
production foundation state.
EOF
  exit 1
fi

if [[ "${MODE}" == "plan" ]]; then
  terraform -chdir="${TF_DIR}" fmt -check -recursive
  terraform -chdir="${TF_DIR}" validate
  terraform -chdir="${TF_DIR}" plan -input=false \
    -var-file="${VAR_FILE}" \
    -out="${PLAN_FILE}"
  printf '[bootstrap] exact production plan saved to %s/%s\n' \
    "${TF_DIR}" "${PLAN_FILE}"
  printf '[bootstrap] review it above or run: terraform show %s\n' "${PLAN_FILE}"
  printf '[bootstrap] apply only with: bash scripts/bootstrap.sh --apply\n'
  exit 0
fi

if [[ ! -f "${TF_DIR}/${PLAN_FILE}" ]]; then
  printf 'ERROR: no reviewed plan at %s/%s; run --plan first\n' \
    "${TF_DIR}" "${PLAN_FILE}" >&2
  exit 1
fi

PROJECT_ID="$({
  terraform -chdir="${TF_DIR}" show -json "${PLAN_FILE}" \
    | jq -er '
        .planned_values.root_module.resources[]
        | select(.address == "google_project.environment")
        | .values.project_id
      '
} 2>/dev/null)" || {
  printf 'ERROR: saved plan does not contain one production project\n' >&2
  exit 1
}

terraform -chdir="${TF_DIR}" show "${PLAN_FILE}"
if [[ "${ASSUME_YES}" -ne 1 ]]; then
  if [[ ! -t 0 ]]; then
    printf 'ERROR: --apply needs an interactive terminal or explicit --yes\n' >&2
    exit 1
  fi
  printf 'Type the production project ID (%s) to apply this exact plan: ' "${PROJECT_ID}"
  read -r confirmation
  if [[ "${confirmation}" != "${PROJECT_ID}" ]]; then
    printf '[bootstrap] cancelled\n'
    exit 1
  fi
fi

terraform -chdir="${TF_DIR}" apply -input=false "${PLAN_FILE}"
rm -f "${TF_DIR}/${PLAN_FILE}"
terraform -chdir="${TF_DIR}" output

cat <<'EOF'

[bootstrap] production foundation applied from the reviewed plan.
Next:
  1. Run scripts/migrate-state.sh to move local state to versioned GCS.
  2. Run scripts/preflight.sh.
  3. Run scripts/repair-host.sh.
  4. Continue with the staged infra foundation plan in ../instructions.md.
EOF
