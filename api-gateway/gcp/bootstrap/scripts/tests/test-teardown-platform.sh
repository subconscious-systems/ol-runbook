#!/usr/bin/env bash
# Unit tests for GCP bootstrap teardown-platform.sh CLI contract (no GCP/IAP).
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "${TEST_DIR}/.." && pwd)"
# shellcheck source=../teardown-platform.sh
source "${SCRIPTS_DIR}/teardown-platform.sh"

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

echo "== CLI help =="
assert_rc "help -h" 0 teardown_platform_parse_args -h
assert_rc "help --help" 0 teardown_platform_parse_args --help

echo "== CLI --yes =="
assert_rc "missing --yes" 2 teardown_platform_parse_args \
  sandbox acme-api-gateway-infra acme-api-gateway
assert_rc "missing names after --yes" 2 teardown_platform_parse_args --yes
assert_rc "environment only after --yes" 2 teardown_platform_parse_args \
  --yes sandbox
assert_rc "one name after --yes" 2 teardown_platform_parse_args \
  --yes sandbox acme-api-gateway-infra
assert_rc "--yes with environment and both names" 0 teardown_platform_parse_args \
  --yes sandbox acme-api-gateway-infra acme-api-gateway
assert_eq "ENV" "${TEARDOWN_ENVIRONMENT}" "sandbox"
assert_eq "INFRA" "${INFRA_DEPLOY_NAME}" "acme-api-gateway-infra"
assert_eq "GATEWAY" "${GATEWAY_DEPLOY_NAME}" "acme-api-gateway"
assert_rc "prod with both names" 0 teardown_platform_parse_args \
  --yes prod acme-api-gateway-infra acme-api-gateway

echo "== CLI validation =="
assert_rc "rejects bad environment" 2 teardown_platform_parse_args \
  --yes staging acme-api-gateway-infra acme-api-gateway
assert_rc "rejects infra uppercase" 2 teardown_platform_parse_args \
  --yes sandbox Acme-Infra acme-api-gateway
assert_rc "rejects gateway underscore" 2 teardown_platform_parse_args \
  --yes sandbox acme-api-gateway-infra acme_api_gateway

echo "== IAP timeout =="
assert_eq "destroy timeout" "$(teardown_platform_iap_timeout)" "7200"

echo "== remote env wiring (script text) =="
if grep -q -- '--entrypoint /app/scripts/teardown-platform.sh' \
    "${SCRIPTS_DIR}/teardown-platform.sh" \
  && grep -q 'TEARDOWN_CONFIRM="${INFRA_DEPLOY_NAME}"' "${SCRIPTS_DIR}/teardown-platform.sh" \
  && grep -q 'GATEWAY_NAMESPACE="${GATEWAY_DEPLOY_NAME}"' "${SCRIPTS_DIR}/teardown-platform.sh" \
  && grep -q 'docker inspect' "${SCRIPTS_DIR}/teardown-platform.sh" \
  && grep -q 'INFRA_DEPLOY_NAME}-gke' "${SCRIPTS_DIR}/teardown-platform.sh" \
  && grep -q -- '--dns-endpoint' "${SCRIPTS_DIR}/teardown-platform.sh" \
  && grep -q 'bootstrap_ssh' "${SCRIPTS_DIR}/teardown-platform.sh" \
  && grep -q 'timeout' "${SCRIPTS_DIR}/teardown-platform.sh"; then
  ok "wrapper copies runner env, overrides entrypoint, sets confirm + namespace, uses IAP"
else
  fail "wrapper missing expected remote env / IAP wiring"
fi

echo
if [[ "${FAIL}" -ne 0 ]]; then
  log "${PASS} passed, ${FAIL} failed"
  exit 1
fi
log "OK: ${PASS} assertions passed"
