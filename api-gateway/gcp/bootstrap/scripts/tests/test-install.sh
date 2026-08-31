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
assert_rc "from-step eleven" 2 install_parse_args --from-step 11
assert_rc "from-step nonnumeric" 2 install_parse_args --from-step nope
assert_rc "mode cannot combine with from-step" 2 \
  install_parse_args --check --from-step 2
assert_rc "noninteractive install fails before actions" 1 \
  bash "${INSTALL_SCRIPT}" --from-step 9

install_parse_args --from-step 6
assert_eq "run mode" "${INSTALL_MODE}" "run"
assert_eq "resume step" "${INSTALL_FROM_STEP}" "6"

install_parse_args --from-step 10
assert_eq "final resume step" "${INSTALL_FROM_STEP}" "10"

install_parse_args --list-steps
assert_eq "list mode" "${INSTALL_MODE}" "list"
assert_eq "ten listed steps" "$(install_list_steps | wc -l | tr -d ' ')" "10"

echo "== Input validation =="
assert_rc "valid infra name" 0 install_assert_dns1123 example-gw-infra INFRA
assert_rc "uppercase rejected" 2 install_assert_dns1123 Example-gw INFRA
assert_rc "underscore rejected" 2 install_assert_dns1123 example_gw INFRA
assert_rc "over 32-char deployment name rejected" 2 install_assert_deployment_name \
  example-api-gateway-infrastructure-long INFRA
assert_rc "long DNS resource name allowed" 0 install_assert_dns1123 \
  example-api-gateway-infrastructure-postgres CLOUDSQL
assert_rc "valid Docker connect URL" 0 install_validate_connect_url \
  'https://app.distr.sh/api/v1/connect?targetId=id&targetSecret=secret'
assert_rc "non-Distr URL rejected" 2 install_validate_connect_url \
  'https://example.com/api/v1/connect?targetId=id&targetSecret=secret'
assert_rc "quoted connect URL rejected" 2 install_validate_connect_url \
  'https://app.distr.sh/api/v1/connect?targetId=id&targetSecret="secret"'
assert_rc "valid Hub command" 0 install_validate_hub_command \
  'kubectl apply -n example-gateway -f "https://app.distr.sh/api/v1/connect?targetId=id&targetSecret=secret"'
assert_rc "partial Hub command rejected" 2 install_validate_hub_command \
  'https://app.distr.sh/api/v1/connect?targetId=id&targetSecret=secret'
assert_rc "matching Hub namespace" 0 install_validate_hub_namespace \
  'kubectl apply -n example-gateway -f "https://app.distr.sh/api/v1/connect?targetId=id&targetSecret=secret"' \
  example-gateway
assert_rc "mismatched Hub namespace rejected" 2 install_validate_hub_namespace \
  'kubectl apply -n wrong-gateway -f "https://app.distr.sh/api/v1/connect?targetId=id&targetSecret=secret"' \
  example-gateway
assert_rc "valid production hostname" 0 install_validate_hostname api.example.com
assert_rc "hostname scheme rejected" 2 install_validate_hostname \
  https://api.example.com
assert_rc "single-label hostname rejected" 2 install_validate_hostname localhost
assert_rc "valid HTTPS URL" 0 install_validate_https_url \
  'https://issuer.example.com/oauth2/default' OIDC
assert_rc "HTTP URL rejected" 2 install_validate_https_url \
  'http://issuer.example.com' OIDC
assert_rc "valid provider suffixes" 0 install_validate_provider_suffixes \
  'api.baseten.co,.provider.example'
assert_rc "provider URL rejected" 2 install_validate_provider_suffixes \
  'https://api.baseten.co/v1'
assert_rc "valid private platform CIDR" 0 install_validate_rfc1918_cidr \
  '10.80.0.0/16' 16 platform
assert_rc "public platform CIDR rejected" 2 install_validate_rfc1918_cidr \
  '8.8.0.0/16' 16 platform
assert_rc "noncanonical platform CIDR rejected" 2 install_validate_rfc1918_cidr \
  '10.80.1.0/16' 16 platform
assert_rc "wrong platform prefix rejected" 2 install_validate_rfc1918_cidr \
  '10.80.0.0/24' 16 platform
assert_rc "non-overlapping CIDRs" 0 install_validate_cidrs_do_not_overlap \
  '10.80.0.0/16' '10.40.0.0/24'
assert_rc "overlapping CIDRs rejected" 2 install_validate_cidrs_do_not_overlap \
  '10.40.0.0/16' '10.40.10.0/24'
assert_eq "safe Hub secret prefix" "$(install_secret_prefix example-prod-gateway)" \
  "EXAMPLE_PROD_GATEWAY"

echo "== Generated Hub environment =="
export INFRA_DEPLOY_NAME=example-gw-infra
export GATEWAY_DEPLOY_NAME=example-gateway
export GCP_PROJECT=example-production
export GCP_REGION=us-east1
export GCP_DNS_PROJECT_ID=example-dns
export DOMAIN_NAME=api.example.com
export DNS_ZONE_NAME=example-public
export TF_STATE_BUCKET=example-production-subconscious-tfstate
export VPC_CIDR=10.80.0.0/16
export DATADOG_ENABLED=false
export DATADOG_SITE=datadoghq.com
export GATEWAY_ROUTE_ALLOWED_HOST_SUFFIXES=provider.example
export GATEWAY_CHART_VERSION=latest
export GATEWAY_AUTO_DEPLOY=false
export DASHBOARD_BOOTSTRAP_SECRET_NAME=EXAMPLE_GATEWAY_GATEWAY_DASHBOARD_BOOTSTRAP_PASSWORD
export DASHBOARD_OIDC_ENABLED=false
export DASHBOARD_OIDC_SECRET_NAME=EXAMPLE_GATEWAY_GATEWAY_DASHBOARD_OIDC_CLIENT_SECRET
export DASHBOARD_OIDC_PROVIDER=generic
export DASHBOARD_OIDC_ISSUER_URL=
export DASHBOARD_OIDC_CLIENT_ID=
export DASHBOARD_BOOTSTRAP_ORG_NAME='Example Production'
export DASHBOARD_BOOTSTRAP_FULL_NAME='Gateway Admin'
export GATEWAY_WEBHOOK_URL=
export GATEWAY_WEBHOOK_SECRET_NAME=EXAMPLE_GATEWAY_GATEWAY_WEBHOOK_SIGNING_SECRET
install_render_gateway_env "${TMP}/gateway-infra.env"
for expected in \
  'DEPLOY_NAME=example-gw-infra' \
  'GATEWAY_DISTR_DEPLOYMENT_NAME=example-gateway' \
  'GCP_PROJECT=example-production' \
  'GCP_DNS_PROJECT_ID=example-dns' \
  'DOMAIN_NAME=api.example.com' \
  'DNS_ZONE_NAME=example-public' \
  'TF_STATE_BUCKET=example-production-subconscious-tfstate' \
  'VPC_CIDR=10.80.0.0/16' \
  'DATADOG_ENABLED=false' \
  'DD_API_KEY=' \
  'DD_APP_KEY=' \
  'DATADOG_GCP_CLOUD_METRICS_ENABLED=false' \
  'DATADOG_ENV=example-production' \
  'GATEWAY_ROUTE_ALLOWED_HOST_SUFFIXES=provider.example' \
  'GATEWAY_CHART_VERSION=latest' \
  'GATEWAY_AUTO_DEPLOY=false'; do
  if grep -Fxq "${expected}" "${TMP}/gateway-infra.env"; then
    ok "generated ${expected%%=*}"
  else
    fail "generated environment missing ${expected}"
  fi
done
if grep -Fq '{{.Secrets.DISTR_TOKEN}}' "${TMP}/gateway-infra.env" \
  && grep -Fq '{{.Secrets.EXAMPLE_GATEWAY_GATEWAY_DASHBOARD_BOOTSTRAP_PASSWORD}}' \
    "${TMP}/gateway-infra.env"; then
  ok "generated environment preserves required Hub Secret references"
else
  fail "generated environment lost Hub Secret references"
fi

export DATADOG_ENABLED=true
export DASHBOARD_OIDC_ENABLED=true
export DASHBOARD_OIDC_PROVIDER=okta
export DASHBOARD_OIDC_ISSUER_URL=https://example.okta.com
export DASHBOARD_OIDC_CLIENT_ID=client-id
export GATEWAY_WEBHOOK_URL=https://events.example.com/gateway
install_render_gateway_env "${TMP}/gateway-infra-optional.env"
for expected in \
  'DD_API_KEY={{.Secrets.DD_API_KEY}}' \
  'DD_APP_KEY={{.Secrets.DD_APP_KEY}}' \
  'DASHBOARD_OIDC_CLIENT_SECRET={{.Secrets.EXAMPLE_GATEWAY_GATEWAY_DASHBOARD_OIDC_CLIENT_SECRET}}' \
  'DASHBOARD_OIDC_ENABLED=true' \
  'DASHBOARD_OIDC_PROVIDER=okta' \
  'DASHBOARD_OIDC_ISSUER_URL=https://example.okta.com' \
  'DASHBOARD_OIDC_CLIENT_ID=client-id' \
  'GATEWAY_WEBHOOK_URL=https://events.example.com/gateway' \
  'GATEWAY_WEBHOOK_SIGNING_SECRET={{.Secrets.EXAMPLE_GATEWAY_GATEWAY_WEBHOOK_SIGNING_SECRET}}'; do
  if grep -Fxq "${expected}" "${TMP}/gateway-infra-optional.env"; then
    ok "generated optional ${expected%%=*}"
  else
    fail "generated optional environment missing ${expected}"
  fi
done

echo "== Guided Hub configuration step =="
GENERATED_ENV="${TMP}/guided-gateway-infra.env"
GENERATED_AUTO_DEPLOY_ENV="${TMP}/guided-gateway-infra-auto-deploy.env"
unset INFRA_DEPLOY_NAME GATEWAY_DEPLOY_NAME DOMAIN_NAME VPC_CIDR
unset GATEWAY_ROUTE_ALLOWED_HOST_SUFFIXES
DATADOG_ENABLED=true
DASHBOARD_OIDC_ENABLED=false
GATEWAY_WEBHOOK_URL=
install_bootstrap_output() {
  case "$1" in
    project_id) printf 'example-production\n' ;;
    region) printf 'us-east1\n' ;;
    dns_project_id) printf 'example-dns\n' ;;
    state_bucket) printf 'example-production-state\n' ;;
    *) return 1 ;;
  esac
}
install_tfvar_string() {
  [[ "$1" == "bootstrap_subnet_cidr" ]] || return 1
  printf '10.40.0.0/24\n'
}
gcloud() {
  case "$*" in
    *'value(dnsName)'*) printf 'example.com.\n' ;;
    *'value(visibility)'*) printf 'public\n' ;;
    *) return 1 ;;
  esac
}
install_wait_for_word() { :; }
# shellcheck disable=SC2218 # The installer definition is sourced above.
printf '%s\n' \
  example-infra example-gateway api.example.com example-public '' \
  api.baseten.co '' false '' '' '' '' \
  | install_step_4 >/dev/null
for expected in \
  'DASHBOARD_BOOTSTRAP_PASSWORD={{.Secrets.EXAMPLE_GATEWAY_GATEWAY_DASHBOARD_BOOTSTRAP_PASSWORD}}' \
  'DD_API_KEY=' \
  'DASHBOARD_OIDC_ENABLED=false' \
  'GATEWAY_WEBHOOK_URL='; do
  if grep -Fxq "${expected}" "${GENERATED_ENV}"; then
    ok "guided step rendered ${expected%%=*}"
  else
    fail "guided step did not render ${expected}"
  fi
done
if grep -Fxq 'GATEWAY_AUTO_DEPLOY=false' "${GENERATED_ENV}" \
  && grep -Fxq 'GATEWAY_AUTO_DEPLOY=true' "${GENERATED_AUTO_DEPLOY_ENV}"; then
  ok "single configuration step rendered both rollout environments"
else
  fail "single configuration step did not render both rollout environments"
fi
if diff -u \
  <(sed 's/^GATEWAY_AUTO_DEPLOY=.*/GATEWAY_AUTO_DEPLOY=<ROLLOUT>/' \
    "${GENERATED_ENV}") \
  <(sed 's/^GATEWAY_AUTO_DEPLOY=.*/GATEWAY_AUTO_DEPLOY=<ROLLOUT>/' \
    "${GENERATED_AUTO_DEPLOY_ENV}") >/dev/null; then
  ok "rollout environments differ only by auto-deploy"
else
  fail "rollout environments contain an unexpected difference"
fi

echo "== Thin-wrapper and secret-handling contract =="
if grep -Fq 'read -r -s value' "${INSTALL_SCRIPT}"; then
  ok "connect input is hidden"
else
  fail "connect input is not hidden"
fi
if grep -Fq 'run-agent.sh" --stdin' "${INSTALL_SCRIPT}" \
  && grep -Fq 'connect-k8s-agent.sh" --stdin' "${INSTALL_SCRIPT}"; then
  ok "installer keeps targetSecret out of child process arguments"
else
  fail "installer passes targetSecret in a child process argument"
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
install_step_10() { DISPATCHED+="0"; }
install_main --from-step 4 >/dev/null
assert_eq "resume runs selected and later steps" "${DISPATCHED}" "4567890"

echo
if [[ "${FAIL}" -ne 0 ]]; then
  log "${PASS} passed, ${FAIL} failed"
  exit 1
fi
log "OK: ${PASS} assertions passed"
