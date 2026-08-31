#!/usr/bin/env bash
# Shared IAP/OS Login and Terraform-output helpers.
# shellcheck shell=bash

BOOTSTRAP_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BOOTSTRAP_TF_DIR="$(cd "${BOOTSTRAP_SCRIPT_DIR}/.." && pwd)"

bootstrap_need() {
  command -v "$1" >/dev/null 2>&1 || {
    printf 'ERROR: %s is required\n' "$1" >&2
    return 1
  }
}

bootstrap_assert_dns1123() {
  local value="${1:-}"
  local label="${2:-value}"
  if [[ ! "${value}" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]]; then
    printf 'ERROR: %s must be a lowercase DNS-1123 label (got: %s)\n' \
      "${label}" "${value}" >&2
    return 2
  fi
}

bootstrap_tf_value() {
  local output_name="$1"
  terraform -chdir="${BOOTSTRAP_TF_DIR}" output -raw "${output_name}" 2>/dev/null
}

bootstrap_resolve_targets() {
  bootstrap_need terraform

  PROJECT_ID="${GCP_PROJECT:-$(bootstrap_tf_value project_id)}"
  REGION="${GCP_REGION:-$(bootstrap_tf_value region)}"
  ZONE="${GCP_ZONE:-$(bootstrap_tf_value zone)}"
  VM_NAME="${BOOTSTRAP_VM_NAME:-$(bootstrap_tf_value vm_name)}"

  for name in PROJECT_ID REGION ZONE VM_NAME; do
    if [[ -z "${!name:-}" || "${!name}" == "null" ]]; then
      printf 'ERROR: could not resolve %s; apply bootstrap Terraform first\n' \
        "${name}" >&2
      return 1
    fi
  done
}

bootstrap_check_gcloud_auth() {
  local account

  bootstrap_need gcloud
  account="$(gcloud auth list --filter=status:ACTIVE --format='value(account)' 2>/dev/null \
    | awk 'NF { print; exit }')"
  if [[ -z "${account}" ]]; then
    printf 'ERROR: no active gcloud user; run scripts/setup-gcloud.sh\n' >&2
    return 1
  fi
}

bootstrap_wait_vm() {
  local status=""
  local attempts_remaining=60

  printf '[bootstrap] waiting for %s in %s/%s\n' "${VM_NAME}" "${PROJECT_ID}" "${ZONE}"
  while [[ "${attempts_remaining}" -gt 0 ]]; do
    status="$(gcloud compute instances describe "${VM_NAME}" \
      --project="${PROJECT_ID}" \
      --zone="${ZONE}" \
      --format='value(status)' 2>/dev/null || true)"
    if [[ "${status}" == "RUNNING" ]]; then
      return 0
    fi
    attempts_remaining=$((attempts_remaining - 1))
    sleep 5
  done

  printf 'ERROR: VM %s did not become RUNNING (last status: %s)\n' \
    "${VM_NAME}" "${status:-unknown}" >&2
  return 1
}

bootstrap_ssh() {
  gcloud compute ssh "${VM_NAME}" \
    --project="${PROJECT_ID}" \
    --zone="${ZONE}" \
    --tunnel-through-iap \
    --quiet \
    "$@"
}

bootstrap_wait_host_ready() {
  local attempts_remaining=60

  printf '[bootstrap] waiting for OS Login and first-boot host setup\n'
  while [[ "${attempts_remaining}" -gt 0 ]]; do
    if bootstrap_ssh \
      --command='sudo test -f /opt/api-gateway-infra/bootstrap-ready' \
      >/dev/null 2>&1; then
      return 0
    fi
    attempts_remaining=$((attempts_remaining - 1))
    sleep 5
  done

  printf 'ERROR: OS Login or first-boot host setup did not become ready within 5 minutes\n' >&2
  printf 'Inspect with: gcloud compute ssh %s --project=%s --zone=%s --tunnel-through-iap\n' \
    "${VM_NAME}" "${PROJECT_ID}" "${ZONE}" >&2
  return 1
}

bootstrap_ensure_host() {
  local setup_path="${1:-${BOOTSTRAP_SCRIPT_DIR}/host-setup.sh}"

  if [[ ! -f "${setup_path}" ]]; then
    printf 'ERROR: host setup script is missing: %s\n' "${setup_path}" >&2
    return 1
  fi

  bootstrap_check_gcloud_auth
  bootstrap_wait_vm

  printf '[bootstrap] applying idempotent host setup to %s/%s\n' \
    "${PROJECT_ID}" "${VM_NAME}"
  bootstrap_ssh \
    --command='sudo tee /usr/local/sbin/api-gateway-infra-host-setup.sh >/dev/null && sudo chmod 0755 /usr/local/sbin/api-gateway-infra-host-setup.sh && sudo /usr/local/sbin/api-gateway-infra-host-setup.sh' \
    <"${setup_path}"
}

bootstrap_print_target() {
  printf '[bootstrap] project=%s region=%s zone=%s vm=%s\n' \
    "${PROJECT_ID}" "${REGION}" "${ZONE}" "${VM_NAME}"
}
