#!/usr/bin/env bash
# Unit tests for bootstrap connect.sh CLI contract (no AWS).
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "${TEST_DIR}/.." && pwd)"
# shellcheck source=../connect.sh
source "${SCRIPTS_DIR}/connect.sh"

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

assert_contains() {
  local name="$1"
  local haystack="$2"
  local needle="$3"
  if [[ "${haystack}" == *"${needle}"* ]]; then
    ok "${name}"
  else
    fail "${name} (missing '${needle}')"
  fi
}

assert_not_contains() {
  local name="$1"
  local haystack="$2"
  local needle="$3"
  if [[ "${haystack}" != *"${needle}"* ]]; then
    ok "${name}"
  else
    fail "${name} (unexpected '${needle}')"
  fi
}

TMP_SQL="$(mktemp)"
trap 'rm -f "${TMP_SQL}"' EXIT
printf 'SELECT 1;' >"${TMP_SQL}"

echo "== CLI help =="
assert_rc "help" 0 connect_parse_args help
assert_eq "help command" "${COMMAND}" "help"
assert_rc "help -h" 0 connect_parse_args -h
assert_rc "help --help" 0 connect_parse_args --help
help_text="$(connect_help 2>&1 || true)"
assert_contains "usage lists help" "${help_text}" "connect.sh help"
assert_contains "usage lists shell" "${help_text}" "connect.sh shell"
assert_contains "usage lists env" "${help_text}" "connect.sh env"
assert_contains "usage lists sql --file" "${help_text}" "--file <sql-file>"
assert_contains "help names AWS_REGION" "${help_text}" "AWS_REGION"
assert_contains "help names session-manager-plugin" "${help_text}" "session-manager-plugin"
assert_contains "help names gateway-secrets" "${help_text}" "gateway-secrets"
assert_contains "help forbids bootstrap" "${help_text}" "bootstrap.sh"
assert_contains "help mentions usage-lag file" "${help_text}" "scripts/sql/usage-lag.sql"
assert_not_contains "help is not named breakglass" "${help_text}" "breakglass"
assert_not_contains "help has no preset" "${help_text}" "--preset"
assert_not_contains "help drops kubectl why" "${help_text}" "Why laptop kubectl"
assert_not_contains "help drops Job why" "${help_text}" "Why sql uses a Kubernetes Job"

echo "== shell / env / compat =="
assert_rc "no args is shell" 0 connect_parse_args
assert_eq "bare command" "${COMMAND}" "shell"
assert_eq "bare infra empty" "${INFRA_DEPLOY_NAME}" ""
assert_rc "legacy name is shell" 0 connect_parse_args acme-api-gateway-infra
assert_eq "legacy command" "${COMMAND}" "shell"
assert_eq "legacy infra" "${INFRA_DEPLOY_NAME}" "acme-api-gateway-infra"
assert_rc "shell subcommand" 0 connect_parse_args shell acme-api-gateway-infra
assert_eq "shell command" "${COMMAND}" "shell"
assert_rc "env ok" 0 connect_parse_args env acme-api-gateway-infra
assert_eq "env command" "${COMMAND}" "env"
assert_eq "env infra" "${INFRA_DEPLOY_NAME}" "acme-api-gateway-infra"
assert_rc "env missing name" 2 connect_parse_args env
assert_rc "unknown flag" 2 connect_parse_args --nope

echo "== sql requires --ns and --file =="
assert_rc "sql without ns" 2 connect_parse_args sql acme-api-gateway-infra --file "${TMP_SQL}"
assert_rc "sql empty ns" 2 connect_parse_args sql acme-api-gateway-infra --ns
assert_rc "sql missing file" 2 connect_parse_args sql acme-api-gateway-infra --ns acme-api-gateway
assert_rc "sql missing file path" 2 connect_parse_args sql acme-api-gateway-infra --ns acme-api-gateway --file
assert_rc "sql unreadable file" 2 connect_parse_args sql acme-api-gateway-infra --ns acme-api-gateway --file /no/such/query.sql
assert_rc "sql inline rejected" 2 connect_parse_args sql acme-api-gateway-infra --ns acme-api-gateway "SELECT 1"
assert_rc "sql file ok" 0 connect_parse_args sql acme-api-gateway-infra --ns acme-api-gateway --file "${TMP_SQL}"
assert_eq "sql ns" "${GATEWAY_NS}" "acme-api-gateway"
assert_eq "sql file" "${SQL_FILE}" "${TMP_SQL}"
assert_eq "sql text" "${SQL_TEXT}" "SELECT 1;"
assert_rc "sql preset rejected" 2 connect_parse_args sql acme-api-gateway-infra --ns acme-api-gateway --preset usage-lag
assert_rc "sql usage-lag file ok" 0 connect_parse_args sql acme-api-gateway-infra --ns acme-api-gateway --file "${SCRIPTS_DIR}/sql/usage-lag.sql"
assert_contains "usage-lag file header" "${SQL_TEXT}" "Export / webhook lag tips"
assert_contains "usage-lag loads tip SQL" "${SQL_TEXT}" "usage.recorded"
assert_contains "usage-lag loads deliveries" "${SQL_TEXT}" "gateway_webhook_deliveries"
assert_rc "ns on env" 2 connect_parse_args env acme-api-gateway-infra --ns acme-api-gateway

echo "== DNS-1123 =="
assert_rc "rejects infra uppercase" 2 connect_parse_args env Acme-Infra
assert_rc "rejects ns underscore" 2 connect_parse_args sql acme-api-gateway-infra --ns acme_api_gateway --file "${TMP_SQL}"

echo "== instance filter =="
assert_eq "instance name" "$(bootstrap_docker_agent_name acme-api-gateway-infra)" "acme-api-gateway-infra-docker-agent"
assert_eq "name filter" "$(bootstrap_ec2_name_filter acme-api-gateway-infra)" \
  "Name=tag:Name,Values=acme-api-gateway-infra-docker-agent"
assert_eq "state filter" "$(bootstrap_ec2_state_filter)" "Name=instance-state-name,Values=running"

echo "== Job YAML never embeds a password =="
job_yaml="$(connect_sql_job_yaml gateway-sql-1 gateway-sql-1)"
assert_contains "uses gateway-secrets" "${job_yaml}" "gateway-secrets"
assert_contains "uses postgres image" "${job_yaml}" "postgres:16-alpine"
assert_contains "statement timeout" "${job_yaml}" "statement_timeout"
assert_contains "gateway-sql label" "${job_yaml}" "gateway-sql"
assert_not_contains "no breakglass label" "${job_yaml}" "breakglass"
assert_not_contains "no password=" "${job_yaml}" "password"
assert_not_contains "no postgres URL" "${job_yaml}" "postgres://"
assert_not_contains "no SecretString" "${job_yaml}" "SecretString"
assert_not_contains "no placeholder secret" "${job_yaml}" "supersecret"

echo
if [[ "${FAIL}" -ne 0 ]]; then
  log "${PASS} passed, ${FAIL} failed"
  exit 1
fi
log "OK: ${PASS} assertions passed"
