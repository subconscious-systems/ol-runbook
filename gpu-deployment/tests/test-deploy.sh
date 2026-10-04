#!/usr/bin/env bash
# Exercise the shared deploy flow with local command doubles; no cloud calls.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"
export DEPLOY_TEST_LOG="$TMP/commands.log"
export DEPLOY_TEST_GPUS=2
export PATH="$TMP/bin:$PATH"
export GCP_PROJECT=test-project GCP_ZONE=test-zone

cat > "$TMP/bin/ssh" <<'SH'
#!/usr/bin/env bash
printf 'ssh %s\n' "$*" >> "$DEPLOY_TEST_LOG"
case "$*" in
  *'printf %s "$HOME"'*) printf /home/test ;;
  *nvidia-smi*) printf '%s\n' "$DEPLOY_TEST_GPUS" ;;
  *'sudo bash'*) exit "${DEPLOY_TEST_BOOTSTRAP_RC:-0}" ;;
esac
SH
cat > "$TMP/bin/scp" <<'SH'
#!/usr/bin/env bash
printf 'scp %s\n' "$*" >> "$DEPLOY_TEST_LOG"
SH
cat > "$TMP/bin/deny-cloud" <<'SH'
#!/usr/bin/env bash
printf 'unexpected cloud command: %s %s\n' "$0" "$*" >> "$DEPLOY_TEST_LOG"
exit 99
SH
chmod +x "$TMP/bin/ssh" "$TMP/bin/scp" "$TMP/bin/deny-cloud"
for cmd in aws gcloud az oci cwctl crusoe curl; do
  ln -s deny-cloud "$TMP/bin/$cmd"
done

fail() { echo "FAIL: $*" >&2; exit 1; }
expect_failure() {
  local expected="$1"
  shift
  if "$@" > "$TMP/output" 2>&1; then
    fail "command unexpectedly succeeded: $*"
  fi
  grep -Fq -- "$expected" "$TMP/output" || { cat "$TMP/output"; fail "missing: $expected"; }
}

# Every provider-first and earlier entry point must identify its selection.
: > "$DEPLOY_TEST_LOG"
count=0
check_help() {
  local wrapper="$1" profile="$2" provider="$3"
  "$wrapper" --help > "$TMP/output"
  grep -Fq "Selected: $profile on $provider (" "$TMP/output" || fail "$wrapper: missing selection"
  grep -Fqi 'environment:' "$TMP/output" || fail "$wrapper: missing provider help"
  count=$((count + 1))
}
for provider in aws gcp azure oci coreweave lambda crusoe nebius together fireworks; do
  for values in "$ROOT"/profiles/*/values.yaml; do
    profile="$(basename "$(dirname "$values")")"
    wrapper="$ROOT/$provider/$profile/deploy.sh"
    test -x "$wrapper" || fail "missing executable $wrapper"
    check_help "$wrapper" "$profile" "$provider"
  done
done
for wrapper in "$ROOT"/profiles/*/*/deploy.sh; do
  provider_dir="$(dirname "$wrapper")"
  provider="$(basename "$provider_dir")"
  profile="$(basename "$(dirname "$provider_dir")")"
  check_help "$wrapper" "$profile" "$provider"
done
test "$count" -gt 0 || fail "no wrappers found"
test ! -s "$DEPLOY_TEST_LOG" || fail "help attempted a remote command"

PROFILE=qwen36-27b-h100-80gb-2gpu
for provider in aws gcp azure oci coreweave lambda crusoe nebius together; do
  : > "$DEPLOY_TEST_LOG"
  SSH_USER=test-operator SSH_KEY="$TMP/test-key" SSH_PORT=2222 \
    "$ROOT/$provider/$PROFILE/deploy.sh" --instance-ip 203.0.113.10 > "$TMP/output"
  grep -Fq 'Host preparation complete' "$TMP/output"
  grep -Fq 'The inference runtime has not been deployed' "$TMP/output"
  grep -Fq 'test-operator@203.0.113.10' "$DEPLOY_TEST_LOG"
  grep -Fq -- '-p 2222' "$DEPLOY_TEST_LOG"
  grep -Fq -- "-i $TMP/test-key" "$DEPLOY_TEST_LOG"
  grep -Fq 'weights.sh' "$DEPLOY_TEST_LOG"
  grep -Fq "$ROOT/$provider/$PROFILE/values.yaml" "$DEPLOY_TEST_LOG"
  grep -Fq "$ROOT/$provider/$PROFILE/weights.sh" "$DEPLOY_TEST_LOG"
  if grep -Fq 'unexpected cloud command' "$DEPLOY_TEST_LOG"; then
    fail "$provider: existing-host path attempted cloud provisioning"
  fi
done

# Omitting SSH_USER must keep the provider's default login user.
: > "$DEPLOY_TEST_LOG"
(unset SSH_USER; "$ROOT/azure/$PROFILE/deploy.sh" --instance-ip 203.0.113.10) > "$TMP/output"
grep -Fq 'azureuser@203.0.113.10' "$DEPLOY_TEST_LOG"

# An installer reboot request must stop before weights and preserve the retry address.
: > "$DEPLOY_TEST_LOG"
set +e
DEPLOY_TEST_BOOTSTRAP_RC=2 "$ROOT/aws/$PROFILE/deploy.sh" --instance-ip 203.0.113.10 > "$TMP/output" 2>&1
rc=$?
set -e
test "$rc" -eq 3 || fail "expected reboot exit 3, got $rc"
grep -Fq -- '--instance-ip 203.0.113.10' "$TMP/output"
grep -Fq -- "/aws/$PROFILE/deploy.sh --instance-ip 203.0.113.10" "$TMP/output"
if grep -Fq '&& ./weights.sh' "$DEPLOY_TEST_LOG"; then
  fail "weight download started despite reboot request"
fi

# Managed providers and invalid options must fail before attempting SSH.
: > "$DEPLOY_TEST_LOG"
for provider in baseten fireworks; do
  expect_failure 'uses a platform deployment' \
    "$ROOT/profiles/$PROFILE/$provider/deploy.sh" --instance-ip 203.0.113.10
done
expect_failure 'uses a platform deployment' \
  "$ROOT/fireworks/$PROFILE/deploy.sh" --instance-ip 203.0.113.10
expect_failure 'automatic provisioning is not implemented for fireworks' \
  "$ROOT/fireworks/$PROFILE/deploy.sh"
wrapper="$ROOT/aws/$PROFILE/deploy.sh"
expect_failure 'requires a value' "$wrapper" --instance-ip
expect_failure 'requires a host address' "$wrapper" --instance-ip ''
expect_failure 'requires a host address' "$wrapper" --instance-ip --help
expect_failure 'unknown option:' "$wrapper" --unknown
test ! -s "$DEPLOY_TEST_LOG" || fail "invalid invocation attempted a remote command"

# Use an isolated profile to exercise .env loading without touching local credentials.
ENV_ROOT="$TMP/profile env"
mkdir -p "$ENV_ROOT/profiles/_providers" "$ENV_ROOT/aws/$PROFILE"
cp "$ROOT/profiles/_deploy.sh" "$ROOT/profiles/_weights.sh" "$ENV_ROOT/profiles/"
cp "$ROOT/profiles/_providers/aws.sh" "$ENV_ROOT/profiles/_providers/"
cp "$ROOT/aws/$PROFILE/"{deploy.sh,values.yaml,weights.sh} "$ENV_ROOT/aws/$PROFILE/"
cat > "$ENV_ROOT/aws/$PROFILE/.env" <<'ENV'
SSH_USER="profile-operator"
SSH_PORT=2200
SSH_KEY='/tmp/key with spaces'
LAMBDA_API_KEY=credential-sentinel
ENV
: > "$DEPLOY_TEST_LOG"
(unset SSH_USER SSH_PORT SSH_KEY; "$ENV_ROOT/aws/$PROFILE/deploy.sh" --instance-ip 203.0.113.10) > "$TMP/output"
grep -Fq 'profile-operator@203.0.113.10' "$DEPLOY_TEST_LOG"
grep -Fq -- '-p 2200' "$DEPLOY_TEST_LOG"
grep -Fq '/tmp/key with spaces' "$DEPLOY_TEST_LOG"
grep -Fq "$ENV_ROOT/aws/$PROFILE/values.yaml" "$DEPLOY_TEST_LOG"
! grep -Fq 'credential-sentinel' "$TMP/output" || fail '.env secret leaked'
: > "$DEPLOY_TEST_LOG"
SSH_USER=caller-operator SSH_PORT=2222 "$ENV_ROOT/aws/$PROFILE/deploy.sh" --instance-ip 203.0.113.10 > "$TMP/output"
grep -Fq 'caller-operator@203.0.113.10' "$DEPLOY_TEST_LOG"
grep -Fq -- '-p 2222' "$DEPLOY_TEST_LOG"

# Literal values must never be evaluated as shell commands.
# shellcheck disable=SC2016  # This intentionally writes literal command-substitution text.
printf 'LAMBDA_API_KEY=$(touch "%s")\n' "$TMP/evaluated-env" > "$ENV_ROOT/aws/$PROFILE/.env"
"$ENV_ROOT/aws/$PROFILE/deploy.sh" --help > "$TMP/output"
test ! -e "$TMP/evaluated-env" || fail '.env executed a command substitution'
printf 'BASH_ENV=/tmp/injected\n' > "$ENV_ROOT/aws/$PROFILE/.env"
expect_failure 'unsupported .env key' "$ENV_ROOT/aws/$PROFILE/deploy.sh" --help
printf 'SSH_USER="unclosed\n' > "$ENV_ROOT/aws/$PROFILE/.env"
expect_failure 'unclosed .env quote' "$ENV_ROOT/aws/$PROFILE/deploy.sh" --help
rm "$ENV_ROOT/aws/$PROFILE/.env" "$ENV_ROOT/aws/$PROFILE/values.yaml"
expect_failure 'missing' "$ENV_ROOT/aws/$PROFILE/deploy.sh" --help

echo "OK: $count wrapper help checks; local profiles/env, existing-host, SSH override, reboot, and managed-provider flows"
