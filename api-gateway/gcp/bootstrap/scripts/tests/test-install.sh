#!/usr/bin/env bash
# Offline tests for the interactive production installer.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "${TEST_DIR}/.." && pwd)"
INSTALL_SCRIPT="${SCRIPTS_DIR}/install.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

# shellcheck source=../install.sh
# shellcheck disable=SC1091
source "${INSTALL_SCRIPT}"

PASS=0
FAIL=0

log() { printf '[test] %s\n' "$*" >&2; }
ok() { PASS=$((PASS + 1)); log "PASS: $*"; }
fail() { FAIL=$((FAIL + 1)); log "FAIL: $*"; }

assert_eq() {
  local name="$1"
  local got="$2"
  local want="$3"
  if [[ "${got}" == "${want}" ]]; then
    ok "${name}"
  else
    fail "${name} (got='${got}' want='${want}')"
  fi
}

assert_rc() {
  local name="$1"
  local want_rc="$2"
  shift 2
  local rc=0
  "$@" >/dev/null 2>&1 || rc=$?
  if [[ "${rc}" -eq "${want_rc}" ]]; then
    ok "${name}"
  else
    fail "${name} (rc=${rc} want=${want_rc})"
  fi
}

echo "== CLI modes =="
assert_rc "help" 0 bash "${INSTALL_SCRIPT}" --help
assert_rc "list" 0 bash "${INSTALL_SCRIPT}" --list-steps
assert_rc "offline check" 0 bash "${INSTALL_SCRIPT}" --check
assert_rc "unknown argument" 2 install_parse_args --unknown
assert_rc "missing from-step value" 2 install_parse_args --from-step
assert_rc "from-step zero" 2 install_parse_args --from-step 0
assert_rc "from-step ten" 2 install_parse_args --from-step 10
assert_rc "from-step nonnumeric" 2 install_parse_args --from-step nope
assert_rc "mode cannot combine with from-step" 2 \
  install_parse_args --check --from-step 2
assert_rc "noninteractive install fails before actions" 1 \
  bash "${INSTALL_SCRIPT}" --from-step 9

install_parse_args --from-step 6
assert_eq "run mode" "${INSTALL_MODE}" "run"
assert_eq "resume step" "${INSTALL_FROM_STEP}" "6"

install_parse_args --list-steps
assert_eq "list mode" "${INSTALL_MODE}" "list"
assert_eq "nine listed steps" "$(install_list_steps | wc -l | tr -d ' ')" "9"

echo "== Input validation =="
assert_rc "valid infra name" 0 install_assert_dns1123 acme-gw-infra INFRA
assert_rc "uppercase rejected" 2 install_assert_dns1123 Acme-gw INFRA
assert_rc "underscore rejected" 2 install_assert_dns1123 acme_gw INFRA
assert_rc "over 32-char deployment name rejected" 2 install_assert_deployment_name \
  acme-api-gateway-infrastructure-long INFRA
assert_rc "long DNS resource name allowed" 0 install_assert_dns1123 \
  acme-api-gateway-infrastructure-postgres CLOUDSQL
assert_rc "valid Docker connect URL" 0 install_validate_connect_url \
  'https://app.distr.sh/api/v1/connect?targetId=id&targetSecret=secret'
assert_rc "non-Distr URL rejected" 2 install_validate_connect_url \
  'https://example.com/api/v1/connect?targetId=id&targetSecret=secret'
assert_rc "valid Hub command" 0 install_validate_hub_command \
  'kubectl apply -n acme-gateway -f "https://app.distr.sh/api/v1/connect?targetId=id&targetSecret=secret"'
assert_rc "partial Hub command rejected" 2 install_validate_hub_command \
  'https://app.distr.sh/api/v1/connect?targetId=id&targetSecret=secret'
assert_rc "matching Hub namespace" 0 install_validate_hub_namespace \
  'kubectl apply -n acme-gateway -f "https://app.distr.sh/api/v1/connect?targetId=id&targetSecret=secret"' \
  acme-gateway
assert_rc "mismatched Hub namespace rejected" 2 install_validate_hub_namespace \
  'kubectl apply -n wrong-gateway -f "https://app.distr.sh/api/v1/connect?targetId=id&targetSecret=secret"' \
  acme-gateway
assert_rc "valid production hostname" 0 install_validate_hostname api.example.com
assert_rc "hostname scheme rejected" 2 install_validate_hostname \
  https://api.example.com
assert_rc "single-label hostname rejected" 2 install_validate_hostname localhost

echo "== Generated Hub environment =="
export INFRA_DEPLOY_NAME=acme-gw-infra
export GATEWAY_DEPLOY_NAME=acme-gateway
export GCP_PROJECT=acme-production
export GCP_REGION=us-east1
export GCP_DNS_PROJECT_ID=acme-dns
export DOMAIN_NAME=api.example.com
export DNS_ZONE_NAME=example-public
export TF_STATE_BUCKET=acme-production-subconscious-tfstate
export VPC_CIDR=10.80.0.0/16
export DATADOG_ENABLED=false
export GATEWAY_ROUTE_ALLOWED_HOST_SUFFIXES=provider.example
install_render_gateway_env "${TMP}/gateway-infra.env"
for expected in \
  'DEPLOY_NAME=acme-gw-infra' \
  'GATEWAY_DISTR_DEPLOYMENT_NAME=acme-gateway' \
  'GCP_PROJECT=acme-production' \
  'GCP_DNS_PROJECT_ID=acme-dns' \
  'DOMAIN_NAME=api.example.com' \
  'DNS_ZONE_NAME=example-public' \
  'TF_STATE_BUCKET=acme-production-subconscious-tfstate' \
  'VPC_CIDR=10.80.0.0/16' \
  'DATADOG_ENABLED=false' \
  'DATADOG_GCP_CLOUD_METRICS_ENABLED=false' \
  'DATADOG_ENV=acme-production' \
  'GATEWAY_ROUTE_ALLOWED_HOST_SUFFIXES=provider.example'; do
  if grep -Fxq "${expected}" "${TMP}/gateway-infra.env"; then
    ok "generated ${expected%%=*}"
  else
    fail "generated environment missing ${expected}"
  fi
done
if grep -Fq '{{.Secrets.DISTR_TOKEN}}' "${TMP}/gateway-infra.env"; then
  ok "generated environment preserves Hub Secret references"
else
  fail "generated environment lost Hub Secret references"
fi

echo "== Thin-wrapper and secret-handling contract =="
if grep -Fq 'read -r -s value' "${INSTALL_SCRIPT}"; then
  ok "connect input is hidden"
else
  fail "connect input is not hidden"
fi
# shellcheck disable=SC2016 # Match literal shell code in the implementation.
if grep -Fq '"${SCRIPT_DIR}/bootstrap.sh"' "${INSTALL_SCRIPT}" \
    && grep -Fq '"${SCRIPT_DIR}/run-agent.sh"' "${INSTALL_SCRIPT}" \
    && grep -Fq '"${SCRIPT_DIR}/connect-k8s-agent.sh"' "${INSTALL_SCRIPT}" \
    && grep -Fq '"${SCRIPT_DIR}/smoke-checks.sh"' "${INSTALL_SCRIPT}"; then
  ok "installer delegates to existing scripts"
else
  fail "installer bypasses an existing script"
fi
if grep -Eq '(curl .*app\.distr\.sh|Authorization:[[:space:]]*Bearer|/api/v1/deploy)' \
    "${INSTALL_SCRIPT}"; then
  fail "installer contains direct Distr API orchestration"
else
  ok "installer has no direct Distr API orchestration"
fi
if grep -Eq '(targetSecret=secret|CONNECT_URL=.*targetSecret)' "${INSTALL_SCRIPT}"; then
  fail "installer contains a resolved connect secret"
else
  ok "installer contains no resolved connect secret"
fi

echo "== Resume dispatch =="
DISPATCHED=""
install_require_terminal() { :; }
install_check_files() { :; }
install_step_1() { DISPATCHED+="1"; }
install_step_2() { DISPATCHED+="2"; }
install_step_3() { DISPATCHED+="3"; }
install_step_4() { DISPATCHED+="4"; }
install_step_5() { DISPATCHED+="5"; }
install_step_6() { DISPATCHED+="6"; }
install_step_7() { DISPATCHED+="7"; }
install_step_8() { DISPATCHED+="8"; }
install_step_9() { DISPATCHED+="9"; }
install_main --from-step 4 >/dev/null
assert_eq "resume runs selected and later steps" "${DISPATCHED}" "456789"

echo
if [[ "${FAIL}" -ne 0 ]]; then
  log "${PASS} passed, ${FAIL} failed"
  exit 1
fi
log "OK: ${PASS} assertions passed"
