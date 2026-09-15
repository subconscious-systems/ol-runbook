# shellcheck shell=bash
# CoreWeave provider: GPU Virtual Server Instances via cwctl.
# Environment:
#   COREWEAVE_FLAVOR   VSI flavor for the profile topology (required; see the
#                      CoreWeave catalog/docs for exact slugs)
#   COREWEAVE_REGION   region (default us-east1)
#   COREWEAVE_IMAGE    VSI image slug (required; verify with CoreWeave docs)
#   SSH_USER           default root
# Notes: CoreWeave flavor slugs and cwctl flags drift; verify with
# `cwctl vs create --help`. If provisioning output parsing fails, create the
# VSI in the CoreWeave console and continue with --instance-ip.
COREWEAVE_REGION="${COREWEAVE_REGION:-us-east1}"
COREWEAVE_FLAVOR="${COREWEAVE_FLAVOR:-}"
COREWEAVE_IMAGE="${COREWEAVE_IMAGE:-}"
SSH_USER="${SSH_USER:-root}"

provider_help() {
  cat <<'EOF'
CoreWeave environment:
  COREWEAVE_FLAVOR, COREWEAVE_REGION, COREWEAVE_IMAGE, SSH_USER
No default flavor map: CoreWeave flavor slugs must be copied from the
CoreWeave catalog. The VSI is created with cwctl; verify flags against
`cwctl vs create --help`. VSIs expose their public IP directly (no extra
firewall step for NodePorts).
EOF
}

resolve_instance_type() {
  local gpu="$1" count="$2"
  if [[ -n "$COREWEAVE_FLAVOR" ]]; then
    INSTANCE_TYPE="$COREWEAVE_FLAVOR"
    return
  fi
  die "set COREWEAVE_FLAVOR to a ${gpu} x ${count} flavor from the CoreWeave catalog"
}

provision() {
  have cwctl || die "install cwctl (https://github.com/coreweave/cwctl) or create the VSI in the console and use --instance-ip"
  [[ -n "$COREWEAVE_IMAGE" ]] || die "set COREWEAVE_IMAGE (CoreWeave image slug for the VSI)"

  log "creating VSI ${INSTANCE_NAME} (flavor ${INSTANCE_TYPE})"
  cwctl vs create \
    --name "$INSTANCE_NAME" \
    --flavor "$INSTANCE_TYPE" \
    --image "$COREWEAVE_IMAGE" \
    --region "$COREWEAVE_REGION"

  SSH_HOST="$(cwctl vs show --name "$INSTANCE_NAME" 2>/dev/null |
    grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}' | head -1 || true)"
  [[ -n "$SSH_HOST" ]] ||
    die "could not read the VSI IP from cwctl; find it in the CoreWeave console and rerun with --instance-ip"
  log "VSI ready at ${SSH_HOST}"
}
