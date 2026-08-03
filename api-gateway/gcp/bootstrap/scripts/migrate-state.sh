#!/usr/bin/env bash
# Migrate the first local bootstrap state into the sandbox foundation bucket.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TF_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
BUCKET=""
PREFIX="bootstrap/gcp-foundation"
ASSUME_YES=0

usage() {
  cat >&2 <<'EOF'
usage: migrate-state.sh [--bucket BUCKET] [--prefix PREFIX] [--yes]

Run after the first local bootstrap apply. By default, the bucket is read from
the recommended_backend_bucket Terraform output. The generated backend.tf and
.backend.hcl are ignored by git.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --bucket)
      [[ $# -ge 2 ]] || {
        usage
        exit 2
      }
      BUCKET="$2"
      shift 2
      ;;
    --prefix)
      [[ $# -ge 2 ]] || {
        usage
        exit 2
      }
      PREFIX="$2"
      shift 2
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

for tool in gcloud terraform; do
  command -v "${tool}" >/dev/null 2>&1 || {
    printf 'ERROR: %s is required\n' "${tool}" >&2
    exit 1
  }
done

if [[ -f "${TF_DIR}/backend.tf" ]]; then
  printf 'ERROR: %s/backend.tf already exists; inspect the current backend before reconfiguring it\n' \
    "${TF_DIR}" >&2
  exit 1
fi

if [[ ! -f "${TF_DIR}/terraform.tfstate" ]]; then
  printf 'ERROR: no local terraform.tfstate found; run bootstrap.sh --apply first\n' >&2
  exit 1
fi

if [[ -z "${BUCKET}" ]]; then
  BUCKET="$(terraform -chdir="${TF_DIR}" output -raw recommended_backend_bucket)"
fi

if [[ ! "${BUCKET}" =~ ^[a-z0-9][a-z0-9._-]{1,61}[a-z0-9]$ ]]; then
  printf 'ERROR: invalid GCS bucket name: %s\n' "${BUCKET}" >&2
  exit 2
fi
if [[ ! "${PREFIX}" =~ ^[A-Za-z0-9][A-Za-z0-9._/-]*[A-Za-z0-9]$ ]] \
  || [[ "${PREFIX}" == *..* || "${PREFIX}" == *//* ]]; then
  printf 'ERROR: prefix must be a safe relative GCS path without traversal or a trailing slash\n' >&2
  exit 2
fi

attempts_remaining=12
until gcloud storage buckets describe "gs://${BUCKET}" >/dev/null 2>&1 \
  && gcloud storage ls "gs://${BUCKET}" >/dev/null 2>&1; do
  attempts_remaining=$((attempts_remaining - 1))
  if [[ "${attempts_remaining}" -eq 0 ]]; then
    printf 'ERROR: state-bucket IAM did not become readable; verify operator_principals and retry\n' >&2
    exit 1
  fi
  printf '[migrate-state] waiting for state-bucket IAM propagation\n'
  sleep 5
done

cat >"${TF_DIR}/backend.tf" <<'EOF'
terraform {
  backend "gcs" {}
}
EOF

cat >"${TF_DIR}/.backend.hcl" <<EOF
bucket = "${BUCKET}"
prefix = "${PREFIX}"
EOF

printf '[migrate-state] destination: gs://%s/%s\n' "${BUCKET}" "${PREFIX}"
if [[ "${ASSUME_YES}" -eq 1 ]]; then
  terraform -chdir="${TF_DIR}" init -input=false -migrate-state -force-copy \
    -backend-config=.backend.hcl
else
  terraform -chdir="${TF_DIR}" init -migrate-state -backend-config=.backend.hcl
fi

terraform -chdir="${TF_DIR}" state list >/dev/null
printf '[migrate-state] remote state initialized and readable\n'
printf '[migrate-state] keep backend.tf and .backend.hcl local; both are gitignored\n'
