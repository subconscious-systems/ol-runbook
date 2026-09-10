#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
AWS_SETUP="$SCRIPT_DIR/terraform/aws-private-workers/setup.sh"
GCP_SETUP="$SCRIPT_DIR/terraform/gcp-workers/setup.sh"

usage() {
  cat <<'EOF'
Configure worker HTTPS domains on AWS or GCP.

Usage:
  ./gpu-deployment/setup.sh
  ./gpu-deployment/setup.sh aws [AWS options]
  ./gpu-deployment/setup.sh gcp [GCP options]
  ./gpu-deployment/setup.sh --cloud aws|gcp [provider options]

With no cloud argument, the CLI prompts for AWS or GCP. It then runs the same
discovery -> terraform.tfvars -> validate -> plan -> optional apply workflow.

Common option:
  --cloud CLOUD       aws or gcp
  -h, --help          Show this global help

AWS options:
  --region REGION     AWS region
  --profile PROFILE   AWS CLI named profile
  --plan-only         Stop after terraform plan

GCP options:
  --project ID        GPU worker project
  --dns-project ID    Cloud DNS project
  --region REGION     GCP region
  --mode MODE         internal or public-api-key
  --plan-only         Stop after terraform plan

Provider-specific help:
  ./gpu-deployment/setup.sh aws --help
  ./gpu-deployment/setup.sh gcp --help
EOF
}

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

select_cloud() {
  local choice

  printf '%s\n' "Cloud provider:" >&2
  printf '%s\n' "  1) AWS" >&2
  printf '%s\n' "  2) GCP" >&2
  while true; do
    read -r -p "Select [1-2]: " choice
    case "$choice" in
      1 | aws | AWS)
        printf '%s\n' "aws"
        return
        ;;
      2 | gcp | GCP)
        printf '%s\n' "gcp"
        return
        ;;
      *)
        printf '%s\n' "Enter 1 for AWS or 2 for GCP." >&2
        ;;
    esac
  done
}

CLOUD=""
PROVIDER_ARGS=()

if [[ $# -gt 0 && ("$1" == "aws" || "$1" == "gcp") ]]; then
  CLOUD="$1"
  shift
fi

while [[ $# -gt 0 ]]; do
  case "$1" in
    --cloud)
      [[ $# -ge 2 ]] || die "--cloud requires aws or gcp"
      [[ -z "$CLOUD" ]] || die "cloud was specified more than once"
      CLOUD="$2"
      shift 2
      ;;
    -h | --help)
      if [[ -z "$CLOUD" ]]; then
        usage
        exit 0
      fi
      PROVIDER_ARGS+=("$1")
      shift
      ;;
    *)
      PROVIDER_ARGS+=("$1")
      shift
      ;;
  esac
done

if [[ -z "$CLOUD" ]]; then
  CLOUD="$(select_cloud)"
fi

case "$CLOUD" in
  aws)
    [[ -x "$AWS_SETUP" ]] || die "AWS setup is missing or not executable: $AWS_SETUP"
    exec "$AWS_SETUP" "${PROVIDER_ARGS[@]}"
    ;;
  gcp)
    [[ -x "$GCP_SETUP" ]] || die "GCP setup is missing or not executable: $GCP_SETUP"
    exec "$GCP_SETUP" "${PROVIDER_ARGS[@]}"
    ;;
  *)
    die "unsupported cloud '$CLOUD'; expected aws or gcp"
    ;;
esac
