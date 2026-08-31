#!/usr/bin/env bash
# Read-only verification of the keyless project/VM foundation.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  printf 'usage: %s\n' "$0"
  exit 0
fi
if [[ $# -ne 0 ]]; then
  printf 'usage: %s\n' "$0" >&2
  exit 2
fi

bootstrap_resolve_targets
bootstrap_check_gcloud_auth
bootstrap_print_target

REQUIRED_APIS=(
  artifactregistry.googleapis.com
  certificatemanager.googleapis.com
  cloudasset.googleapis.com
  cloudbilling.googleapis.com
  cloudresourcemanager.googleapis.com
  compute.googleapis.com
  container.googleapis.com
  dns.googleapis.com
  iam.googleapis.com
  iamcredentials.googleapis.com
  iap.googleapis.com
  logging.googleapis.com
  monitoring.googleapis.com
  orgpolicy.googleapis.com
  oslogin.googleapis.com
  redis.googleapis.com
  secretmanager.googleapis.com
  servicenetworking.googleapis.com
  serviceusage.googleapis.com
  sqladmin.googleapis.com
  storage.googleapis.com
  sts.googleapis.com
)

ENABLED_APIS="$(gcloud services list --enabled \
  --project="${PROJECT_ID}" \
  --format='value(config.name)')"

FAILURES=0
for api in "${REQUIRED_APIS[@]}"; do
  if ! grep -Fxq "${api}" <<<"${ENABLED_APIS}"; then
    printf 'ERROR: required API is not enabled: %s\n' "${api}" >&2
    FAILURES=$((FAILURES + 1))
  fi
done

gcloud billing projects describe "${PROJECT_ID}" --format=json \
  | jq -e '.billingEnabled == true' >/dev/null || {
  printf 'ERROR: billing is not enabled for %s\n' "${PROJECT_ID}" >&2
  FAILURES=$((FAILURES + 1))
}

VM_JSON="$(gcloud compute instances describe "${VM_NAME}" \
  --project="${PROJECT_ID}" \
  --zone="${ZONE}" \
  --format=json)"

if ! jq -e '[.networkInterfaces[].accessConfigs[]?] | length == 0' \
  <<<"${VM_JSON}" >/dev/null; then
  printf 'ERROR: bootstrap VM has a public access configuration\n' >&2
  FAILURES=$((FAILURES + 1))
fi

if ! jq -e '.metadata.items | any(.key == "enable-oslogin" and .value == "TRUE")' \
  <<<"${VM_JSON}" >/dev/null; then
  printf 'ERROR: OS Login is not enabled on the bootstrap VM\n' >&2
  FAILURES=$((FAILURES + 1))
fi

SERVICE_ACCOUNT="$(bootstrap_tf_value bootstrap_service_account)"
DNS_PROJECT_ID="$(bootstrap_tf_value dns_project_id)"
if ! jq -e '
    (.metadata.items | any(.key == "block-project-ssh-keys" and .value == "TRUE"))
    and .shieldedInstanceConfig.enableSecureBoot == true
    and .shieldedInstanceConfig.enableVtpm == true
    and .shieldedInstanceConfig.enableIntegrityMonitoring == true' \
  <<<"${VM_JSON}" >/dev/null; then
  printf 'ERROR: project SSH-key blocking or Shielded VM protections are missing\n' >&2
  FAILURES=$((FAILURES + 1))
fi
if ! jq -e --arg service_account "${SERVICE_ACCOUNT}" '
    (.serviceAccounts | length == 1)
    and .serviceAccounts[0].email == $service_account
    and (.serviceAccounts[0].scopes | index("https://www.googleapis.com/auth/cloud-platform") != null)' \
  <<<"${VM_JSON}" >/dev/null; then
  printf 'ERROR: bootstrap VM service-account attachment or OAuth scope differs from Terraform output\n' >&2
  FAILURES=$((FAILURES + 1))
fi

USER_KEYS="$(gcloud iam service-accounts keys list \
  --project="${PROJECT_ID}" \
  --iam-account="${SERVICE_ACCOUNT}" \
  --filter='keyType=USER_MANAGED' \
  --format='value(name)')"
if [[ -n "${USER_KEYS}" ]]; then
  printf 'ERROR: user-managed keys exist for %s; investigate and revoke them\n' \
    "${SERVICE_ACCOUNT}" >&2
  FAILURES=$((FAILURES + 1))
fi

DNS_IAM_READY=0
for _ in $(seq 1 12); do
  if gcloud projects get-iam-policy "${DNS_PROJECT_ID}" --format=json \
    | jq -e --arg member "serviceAccount:${SERVICE_ACCOUNT}" \
      'any(.bindings[]?; .role == "roles/dns.admin" and any(.members[]?; . == $member))' \
      >/dev/null; then
    DNS_IAM_READY=1
    break
  fi
  sleep 5
done
if [[ "${DNS_IAM_READY}" -ne 1 ]]; then
  printf 'ERROR: %s does not have roles/dns.admin in %s\n' \
    "${SERVICE_ACCOUNT}" "${DNS_PROJECT_ID}" >&2
  FAILURES=$((FAILURES + 1))
fi

gcloud compute routers nats describe "gateway-bootstrap" \
  --project="${PROJECT_ID}" \
  --region="${REGION}" \
  --router="gateway-bootstrap" \
  --format='value(name)' >/dev/null

if [[ "${FAILURES}" -ne 0 ]]; then
  printf 'ERROR: preflight found %s issue(s)\n' "${FAILURES}" >&2
  exit 1
fi

bootstrap_wait_vm
bootstrap_wait_host_ready

printf '[preflight] OK: billing, APIs, DNS IAM, private Shielded VM, OS Login, NAT, keyless SA, and host readiness\n'
