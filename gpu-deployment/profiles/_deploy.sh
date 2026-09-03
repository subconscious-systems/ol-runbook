#!/usr/bin/env bash
# Shared implementation used by each profile/provider deploy.sh wrapper.
# Provisions one GPU instance on the selected cloud, bootstraps the host with
# the ol-runbook installer, stages values.yaml/weights.sh, and starts the
# interactive weight download. The final Distr Apply steps stay with the
# operator (ol-runbook documents that automation boundary) and are printed at
# the end. Cloud specifics live in _providers/<provider>.sh.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROVIDERS=(aws gcp azure oci coreweave lambda crusoe nebius baseten together fireworks)
INSTALL_SH_URL="${INSTALL_SH_URL:-https://raw.githubusercontent.com/subconscious-systems/ol-runbook/main/gpu-deployment/profiles/install.sh}"
SSH_WAIT_TIMEOUT_SECONDS="${SSH_WAIT_TIMEOUT_SECONDS:-900}"
SSH_KEY="${SSH_KEY:-$HOME/.ssh/id_ed25519}"
SSH_PORT="${SSH_PORT:-22}"
NAMESPACE="${NAMESPACE:-sglang}"

log() { printf '[deploy] %s\n' "$*"; }
die() { printf '[deploy] ERROR: %s\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

usage() {
  cat <<'EOF'
Usage: _deploy.sh <provider> <gpu> <gpu-count> <profile> [--instance-ip <ip>]

Called by profiles/<profile>/<provider>/deploy.sh. Provisions a GPU instance
matching the profile topology, bootstraps the host with the ol-runbook
installer (drivers, k3s, NVIDIA device plugin), stages the profile files,
and runs the interactive weight download. --instance-ip skips provisioning
and continues on an existing host.

Providers: aws gcp azure oci coreweave lambda crusoe nebius baseten together fireworks
GPU slugs:  l4 l40s a100-80gb h100-80gb h200 b200

Per-provider environment variables (instance type override, region, keys)
are described by each _providers/<provider>.sh header comment.
EOF
}

POSITIONAL=()
INSTANCE_IP_FLAG=""
while (($#)); do
  case "$1" in
    -h | --help)
      usage
      exit 0
      ;;
    --instance-ip)
      [[ $# -ge 2 ]] || die "--instance-ip requires a value"
      INSTANCE_IP_FLAG="$2"
      shift 2
      ;;
    *)
      POSITIONAL+=("$1")
      shift
      ;;
  esac
done
((${#POSITIONAL[@]} == 4)) || { usage >&2; exit 2; }
read -r PROVIDER GPU GPU_COUNT PROFILE <<<"${POSITIONAL[*]}"

case "$PROVIDER" in
  aws | gcp | azure | oci | coreweave | lambda | crusoe | nebius | baseten | together | fireworks) ;;
  *) die "unknown provider: ${PROVIDER} (expected one of: ${PROVIDERS[*]})" ;;
esac
case "$GPU" in
  l4 | l40s | a100-80gb | h100-80gb | h200 | b200) ;;
  *) die "unknown gpu slug: ${GPU}" ;;
esac
case "$GPU_COUNT" in
  1 | 2 | 4 | 8) ;;
  *) die "invalid gpu count: ${GPU_COUNT}" ;;
esac

PROFILE_DIR="${SCRIPT_DIR}/${PROFILE}"
[[ -f "${PROFILE_DIR}/values.yaml" ]] || die "missing ${PROFILE_DIR}/values.yaml"
[[ -x "${PROFILE_DIR}/weights.sh" ]] || die "missing ${PROFILE_DIR}/weights.sh"
[[ -f "${SCRIPT_DIR}/_weights.sh" ]] || die "missing ${SCRIPT_DIR}/_weights.sh"

PROVIDER_FILE="${SCRIPT_DIR}/_providers/${PROVIDER}.sh"
[[ -f "${PROVIDER_FILE}" ]] || die "missing ${PROVIDER_FILE}"

SSH_OPTS=(-o StrictHostKeyChecking=accept-new -o ServerAliveInterval=30)
SSH_HOST=""
SSH_USER=""

remote_run() {
  ssh "${SSH_OPTS[@]}" -i "${SSH_KEY}" -p "${SSH_PORT}" "${SSH_USER}@${SSH_HOST}" -- "$@"
}

remote_interactive() {
  ssh -tt "${SSH_OPTS[@]}" -i "${SSH_KEY}" -p "${SSH_PORT}" "${SSH_USER}@${SSH_HOST}" -- "$@"
}

remote_copy() {
  scp "${SSH_OPTS[@]}" -i "${SSH_KEY}" -P "${SSH_PORT}" -- "$1" "${SSH_USER}@${SSH_HOST}:$2"
}

remote_wait() {
  local elapsed=0
  log "waiting for SSH access to ${SSH_HOST}"
  while ((elapsed < SSH_WAIT_TIMEOUT_SECONDS)); do
    if remote_run true >/dev/null 2>&1; then
      log "SSH ready"
      return 0
    fi
    sleep 10
    elapsed=$((elapsed + 10))
  done
  die "timed out waiting for SSH on ${SSH_HOST}"
}

require_pub_key() {
  [[ -f "${SSH_KEY}.pub" ]] ||
    die "public key ${SSH_KEY}.pub is required; create a key pair or set SSH_KEY"
}

# shellcheck disable=SC1090
source "${PROVIDER_FILE}"
[[ "$(declare -Ff resolve_instance_type 2>/dev/null)" ]] || die "${PROVIDER_FILE} does not define resolve_instance_type"
[[ "$(declare -Ff provision 2>/dev/null)" ]] || die "${PROVIDER_FILE} does not define provision"

if [[ -n "$INSTANCE_IP_FLAG" ]]; then
  [[ -n "${SSH_HOST}" ]] || die "provider ${PROVIDER} did not default SSH_HOST for --instance-ip; set it"
  SSH_HOST="$INSTANCE_IP_FLAG"
  log "skipping provisioning; continuing on ${SSH_HOST}"
else
  resolve_instance_type "$GPU" "$GPU_COUNT"
  INSTANCE_NAME="${INSTANCE_NAME:-${PROFILE}-${PROVIDER}-$(date +%y%m%d-%H%M)}"
  log "provisioning ${INSTANCE_NAME} (${GPU} x ${GPU_COUNT})"
  provision
fi

[[ -n "${SSH_HOST}" ]] || die "provisioning did not set SSH_HOST"
[[ -n "${SSH_USER}" ]] || die "SSH_USER is empty; set it for ${PROVIDER}"
remote_wait

# shellcheck disable=SC2016  # remote side must expand $HOME
REMOTE_HOME="$(remote_run 'printf %s "$HOME"')" || die "could not resolve remote home directory"
REMOTE_PROFILE_DIR="${REMOTE_HOME}/${PROFILE}"

log "staging ${PROFILE} onto ${SSH_HOST}:${REMOTE_PROFILE_DIR}"
remote_run "mkdir -p '${REMOTE_PROFILE_DIR}'" || die "could not create ${REMOTE_PROFILE_DIR}"
remote_copy "${PROFILE_DIR}/values.yaml" "${REMOTE_PROFILE_DIR}/values.yaml" ||
  die "could not stage values.yaml"
remote_copy "${PROFILE_DIR}/weights.sh" "${REMOTE_PROFILE_DIR}/weights.sh" ||
  die "could not stage weights.sh"
remote_copy "${SCRIPT_DIR}/_weights.sh" "${REMOTE_HOME}/_weights.sh" ||
  die "could not stage _weights.sh"
remote_run "chmod +x '${REMOTE_PROFILE_DIR}/weights.sh' '${REMOTE_HOME}/_weights.sh'"

log "bootstrapping the host with the ol-runbook installer"
set +e
if [[ -f "${SCRIPT_DIR}/install.sh" ]]; then
  remote_copy "${SCRIPT_DIR}/install.sh" "${REMOTE_HOME}/subconscious-install.sh"
  BOOTSTRAP_RC=$?
  if ((BOOTSTRAP_RC == 0)); then
    remote_interactive "chmod +x '${REMOTE_HOME}/subconscious-install.sh' && sudo bash '${REMOTE_HOME}/subconscious-install.sh'"
    BOOTSTRAP_RC=$?
  fi
else
  remote_interactive "curl -fsSL '${INSTALL_SH_URL}' -o /tmp/subconscious-install.sh && sudo bash /tmp/subconscious-install.sh"
  BOOTSTRAP_RC=$?
fi
set -e
if ((BOOTSTRAP_RC == 2)); then
  cat >&2 <<EOF
[deploy] The installer requested a host reboot for NVIDIA drivers.
[deploy] Reboot the instance, wait for SSH, then continue with:
[deploy]   ${PROFILE}/${PROVIDER}/deploy.sh --instance-ip ${SSH_HOST}
EOF
  exit 3
fi
((BOOTSTRAP_RC == 0)) || die "host bootstrap failed (exit ${BOOTSTRAP_RC})"

GPU_FOUND="$(remote_run "nvidia-smi -L | grep -c 'GPU (' || true")"
if [[ "$GPU_FOUND" != "$GPU_COUNT" ]]; then
  log "WARNING: expected ${GPU_COUNT} ${GPU} GPUs; nvidia-smi reports ${GPU_FOUND}"
fi

log "downloading profile weights (interactive Hugging Face token prompt)"
remote_interactive "cd '${REMOTE_PROFILE_DIR}' && ./weights.sh"

cat <<EOF

Instance ready on ${PROVIDER}: ${SSH_HOST} (${GPU} x ${GPU_COUNT})
Profile staged at: ${REMOTE_PROFILE_DIR}

Remaining Distr steps (ol-runbook gpu-deployment):
  1. Distr Hub Secrets: WORKER_API_KEY (gateway dashboard) and DD_API_KEY.
  2. Deployments -> New Deployment -> SGLang application, namespace ${NAMESPACE}.
  3. Paste ${REMOTE_PROFILE_DIR}/values.yaml into App Config -> Helm Values (full replace).
  4. Run the Distr connect command on the instance, wait for the target, and Apply.
  5. Worker URL and dashboard registration: ol-runbook gpu-deployment steps 4-5.

EOF
log "done"
