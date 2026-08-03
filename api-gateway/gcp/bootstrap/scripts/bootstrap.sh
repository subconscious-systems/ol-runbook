#!/usr/bin/env bash
# Plan or explicitly apply the staged GCP bootstrap foundation.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TF_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
MODE="plan"
ASSUME_YES=0
PLAN_FILE=".bootstrap.tfplan"

usage() {
  cat >&2 <<'EOF'
usage: bootstrap.sh [--plan] [--apply [--yes]]

Default is plan-only. --apply requires an interactive confirmation unless
--yes is also supplied. This stack creates only environments selected by
enabled_environments; start with sandbox and add prod after explicit approval.
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

for tool in gcloud terraform; do
  command -v "${tool}" >/dev/null 2>&1 || {
    printf 'ERROR: %s is required\n' "${tool}" >&2
    exit 1
  }
done

if [[ ! -f "${TF_DIR}/terraform.tfvars" ]]; then
  printf 'ERROR: copy terraform.tfvars.example to terraform.tfvars and replace every example value\n' >&2
  exit 1
fi

gcloud auth application-default print-access-token >/dev/null

terraform -chdir="${TF_DIR}" fmt -check -recursive
terraform -chdir="${TF_DIR}" init -input=false
terraform -chdir="${TF_DIR}" validate
terraform -chdir="${TF_DIR}" plan -input=false -out="${PLAN_FILE}"

if [[ "${MODE}" == "plan" ]]; then
  printf '[bootstrap] plan saved to %s/%s; no cloud changes were made\n' \
    "${TF_DIR}" "${PLAN_FILE}"
  exit 0
fi

if [[ "${ASSUME_YES}" -ne 1 ]]; then
  if [[ ! -t 0 ]]; then
    printf 'ERROR: --apply needs an interactive terminal or explicit --yes\n' >&2
    exit 1
  fi
  printf 'Type APPLY to create/update only the environments in enabled_environments: '
  read -r confirmation
  if [[ "${confirmation}" != "APPLY" ]]; then
    printf '[bootstrap] cancelled\n'
    exit 1
  fi
fi

terraform -chdir="${TF_DIR}" apply -input=false "${PLAN_FILE}"
terraform -chdir="${TF_DIR}" output

cat <<'EOF'

[bootstrap] foundation applied.
Next:
  1. Run scripts/migrate-state.sh to move local state to versioned GCS.
  2. Run scripts/preflight.sh sandbox (and prod only if it was approved/enabled).
  3. Run scripts/repair-host.sh for each enabled environment.
  4. Do not enable prod until the sandbox rebuild evidence is approved.
EOF
