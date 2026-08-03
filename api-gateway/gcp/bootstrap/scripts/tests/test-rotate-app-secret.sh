#!/usr/bin/env bash
# Unit tests for the GCP rotation wrapper CLI (no cloud calls).
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "${TEST_DIR}/.." && pwd)"
# shellcheck source=rotate-app-secret.sh
source "${SCRIPTS_DIR}/rotate-app-secret.sh"

PASS=0
FAIL=0

assert_rc() {
  local name="$1"
  local expected="$2"
  shift 2
  local actual=0
  "$@" >/dev/null 2>&1 || actual=$?
  if [[ "${actual}" -eq "${expected}" ]]; then
    PASS=$((PASS + 1))
    printf '[test] PASS: %s\n' "${name}"
  else
    FAIL=$((FAIL + 1))
    printf '[test] FAIL: %s (got %s, expected %s)\n' \
      "${name}" "${actual}" "${expected}" >&2
  fi
}

assert_rc "sandbox csrf" 0 \
  rotate_parse_args sandbox csrf acme-gateway-infra acme-gateway
assert_rc "prod encryption" 0 \
  rotate_parse_args prod encryption acme-gateway-infra acme-gateway
assert_rc "uppercase key alias" 0 \
  rotate_parse_args prod CSRF acme-gateway-infra acme-gateway
assert_rc "bad environment" 2 \
  rotate_parse_args staging csrf acme-gateway-infra acme-gateway
assert_rc "bad key" 2 \
  rotate_parse_args prod router acme-gateway-infra acme-gateway
assert_rc "bad infra label" 2 \
  rotate_parse_args prod csrf Acme_Gateway acme-gateway
assert_rc "bad gateway label" 2 \
  rotate_parse_args prod csrf acme-gateway-infra -gateway
assert_rc "missing argument" 2 \
  rotate_parse_args prod csrf acme-gateway-infra

if [[ "${FAIL}" -ne 0 ]]; then
  printf '[test] %s passed, %s failed\n' "${PASS}" "${FAIL}" >&2
  exit 1
fi
printf '[test] OK: %s assertions passed\n' "${PASS}"
