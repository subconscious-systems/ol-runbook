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

assert_rc "encryption" 0 \
  rotate_parse_args encryption example-gateway-infra example-gateway
assert_rc "uppercase key alias" 0 \
  rotate_parse_args CSRF example-gateway-infra example-gateway
assert_rc "bad key" 2 \
  rotate_parse_args router example-gateway-infra example-gateway
assert_rc "bad infra label" 2 \
  rotate_parse_args csrf Example_Gateway example-gateway
assert_rc "bad gateway label" 2 \
  rotate_parse_args csrf example-gateway-infra -gateway
assert_rc "missing argument" 2 \
  rotate_parse_args csrf example-gateway-infra

if [[ "${FAIL}" -ne 0 ]]; then
  printf '[test] %s passed, %s failed\n' "${PASS}" "${FAIL}" >&2
  exit 1
fi
printf '[test] OK: %s assertions passed\n' "${PASS}"
