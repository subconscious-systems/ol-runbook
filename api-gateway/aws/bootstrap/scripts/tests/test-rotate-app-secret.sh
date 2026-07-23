#!/usr/bin/env bash
# Unit tests for bootstrap rotate-app-secret.sh CLI contract (no AWS/SSM).
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "${TEST_DIR}/.." && pwd)"
# shellcheck source=../rotate-app-secret.sh
source "${SCRIPTS_DIR}/rotate-app-secret.sh"

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
assert_rc "help -h" 0 rotate_app_secret_parse_args -h
assert_rc "help --help" 0 rotate_app_secret_parse_args --help

echo "== CLI arity =="
assert_rc "missing args" 2 rotate_app_secret_parse_args
assert_rc "one arg" 2 rotate_app_secret_parse_args csrf
assert_rc "two args" 2 rotate_app_secret_parse_args csrf infra-name

echo "== CLI key aliases =="
assert_rc "csrf ok" 0 rotate_app_secret_parse_args csrf acme-api-gateway-infra acme-api-gateway
assert_eq "csrf KEY_ALIAS" "${KEY_ALIAS}" "csrf"
assert_eq "csrf INFRA" "${INFRA_DEPLOY_NAME}" "acme-api-gateway-infra"
assert_eq "csrf GATEWAY" "${GATEWAY_DEPLOY_NAME}" "acme-api-gateway"

assert_rc "encryption ok" 0 rotate_app_secret_parse_args encryption acme-api-gateway-infra acme-api-gateway
assert_eq "encryption KEY_ALIAS" "${KEY_ALIAS}" "encryption"

assert_rc "CSRF uppercased" 0 rotate_app_secret_parse_args CSRF acme-api-gateway-infra acme-api-gateway
assert_eq "CSRF normalized" "${KEY_ALIAS}" "csrf"

assert_rc "ENCRYPTION uppercased" 0 rotate_app_secret_parse_args ENCRYPTION acme-api-gateway-infra acme-api-gateway
assert_eq "ENCRYPTION normalized" "${KEY_ALIAS}" "encryption"

assert_rc "rejects router" 2 rotate_app_secret_parse_args router acme-api-gateway-infra acme-api-gateway
assert_rc "rejects full key name" 2 rotate_app_secret_parse_args \
  SUBCONSCIOUS_GATEWAY_DASHBOARD_CSRF_SECRET acme-api-gateway-infra acme-api-gateway

echo "== CLI DNS-1123 =="
assert_rc "rejects infra uppercase" 2 rotate_app_secret_parse_args csrf Acme-Infra acme-api-gateway
assert_rc "rejects gateway underscore" 2 rotate_app_secret_parse_args csrf acme-api-gateway-infra acme_api_gateway
assert_rc "rejects empty-looking bad label" 2 rotate_app_secret_parse_args csrf -bad acme-api-gateway

echo "== SSM timeouts =="
assert_eq "csrf timeout" "$(rotate_app_secret_ssm_timeout csrf)" "2400"
assert_eq "encryption timeout" "$(rotate_app_secret_ssm_timeout encryption)" "1800"

echo "== remote env wiring (script text) =="
if grep -q 'DEPLOY_NAME=\${INFRA_Q}' "${SCRIPTS_DIR}/rotate-app-secret.sh" \
  && grep -q 'GATEWAY_NAMESPACE=\${GATEWAY_Q}' "${SCRIPTS_DIR}/rotate-app-secret.sh" \
  && grep -q 'CLUSTER_NAME=\${INFRA_Q}' "${SCRIPTS_DIR}/rotate-app-secret.sh" \
  && grep -q 'KEY=\${KEY_Q}' "${SCRIPTS_DIR}/rotate-app-secret.sh" \
  && grep -q 'bootstrap_ssm_run' "${SCRIPTS_DIR}/rotate-app-secret.sh" \
  && grep -q 'rotate-gateway-app-secret.sh' "${SCRIPTS_DIR}/rotate-app-secret.sh"; then
  ok "wrapper forwards infra/gateway names + KEY via SSM docker run"
else
  fail "wrapper missing expected remote env / SSM wiring"
fi

echo
if [[ "${FAIL}" -ne 0 ]]; then
  log "${PASS} passed, ${FAIL} failed"
  exit 1
fi
log "OK: ${PASS} assertions passed"
