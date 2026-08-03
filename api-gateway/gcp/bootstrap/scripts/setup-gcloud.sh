#!/usr/bin/env bash
# Configure local user and Application Default Credentials for Terraform.
set -euo pipefail

PROJECT_ID=""
SKIP_LOGIN=0

usage() {
  cat >&2 <<'EOF'
usage: setup-gcloud.sh [--quota-project EXISTING_PROJECT_ID] [--skip-login]

Authenticates the local human user and Application Default Credentials (ADC).
No service-account key is created. The optional quota project must already
exist and must grant the user serviceusage.services.use.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --quota-project)
      [[ $# -ge 2 ]] || {
        usage
        exit 2
      }
      PROJECT_ID="$2"
      shift 2
      ;;
    --skip-login)
      SKIP_LOGIN=1
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

command -v gcloud >/dev/null 2>&1 || {
  printf 'ERROR: gcloud is required; run install-gcloud.sh first\n' >&2
  exit 1
}

if [[ "${SKIP_LOGIN}" -eq 0 ]]; then
  if [[ ! -t 0 ]]; then
    printf 'ERROR: login is interactive; run this script from a terminal or use --skip-login\n' >&2
    exit 1
  fi
  gcloud auth login
  gcloud auth application-default login
fi

ACTIVE_ACCOUNT="$(gcloud auth list --filter=status:ACTIVE --format='value(account)' \
  | awk 'NF { print; exit }')"
if [[ -z "${ACTIVE_ACCOUNT}" ]]; then
  printf 'ERROR: no active gcloud user account\n' >&2
  exit 1
fi

gcloud auth application-default print-access-token >/dev/null

if [[ -n "${PROJECT_ID}" ]]; then
  gcloud config set project "${PROJECT_ID}"
  gcloud auth application-default set-quota-project "${PROJECT_ID}"
fi
gcloud config set compute/region us-east1

printf '[setup-gcloud] active user: %s\n' "${ACTIVE_ACCOUNT}"
printf '[setup-gcloud] ADC: ready (token not displayed)\n'
printf '[setup-gcloud] region: us-east1\n'
