# shellcheck shell=bash
# Crusoe provider: GPU VMs via the Crusoe CLI.
# Environment:
#   CRUSOE_INSTANCE_TYPE  VM type (defaults for H100/H200; set explicitly for
#                         anything else — see `crusoe` docs for exact slugs)
#   CRUSOE_LOCATION       location (default us-east-1)
#   CRUSOE_IMAGE          image slug (default ubuntu-22.04; verify with
#                         `crusoe` docs/images list)
#   SSH_USER              default ubuntu
# Notes: Crusoe CLI flags and type slugs drift; verify with
# `crusoe vm create --help`. If output parsing fails, create the VM in the
# Crusoe console and continue with --instance-ip.
CRUSOE_LOCATION="${CRUSOE_LOCATION:-us-east-1}"
CRUSOE_INSTANCE_TYPE="${CRUSOE_INSTANCE_TYPE:-}"
CRUSOE_IMAGE="${CRUSOE_IMAGE:-ubuntu-22.04}"
SSH_USER="${SSH_USER:-ubuntu}"

provider_help() {
  cat <<'EOF'
Crusoe environment:
  CRUSOE_INSTANCE_TYPE, CRUSOE_LOCATION, CRUSOE_IMAGE, SSH_KEY, SSH_USER
Defaults exist for h100-80gb (h100-80gb.N) and h200 (h200-141gb.N) only;
set CRUSOE_INSTANCE_TYPE for other GPUs. VMs expose their public IP
directly (no extra firewall step for NodePorts).
EOF
}

resolve_instance_type() {
  local gpu="$1" count="$2"
  if [[ -n "$CRUSOE_INSTANCE_TYPE" ]]; then
    INSTANCE_TYPE="$CRUSOE_INSTANCE_TYPE"
    return
  fi
  case "$gpu" in
    h100-80gb) INSTANCE_TYPE="h100-80gb.${count}" ;;
    h200) INSTANCE_TYPE="h200-141gb.${count}" ;;
    *) die "no default Crusoe type for ${gpu} x ${count}; set CRUSOE_INSTANCE_TYPE" ;;
  esac
  log "VM type: ${INSTANCE_TYPE}"
}

provision() {
  have crusoe || die "install the Crusoe CLI (https://developers.crusoe.ai) or create the VM in the console and use --instance-ip"
  require_pub_key

  log "creating VM ${INSTANCE_NAME} (type ${INSTANCE_TYPE})"
  crusoe vm create \
    --name "$INSTANCE_NAME" \
    --type "$INSTANCE_TYPE" \
    --location "$CRUSOE_LOCATION" \
    --image "$CRUSOE_IMAGE" \
    --ssh-public-key "$(cat "${SSH_KEY}.pub")"

  SSH_HOST="$(crusoe vm show --name "$INSTANCE_NAME" 2>/dev/null |
    grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}' | head -1 || true)"
  [[ -n "$SSH_HOST" ]] ||
    die "could not read the VM IP from crusoe; find it in the Crusoe console and rerun with --instance-ip"
  log "VM ready at ${SSH_HOST}"
}
