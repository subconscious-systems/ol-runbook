# shellcheck shell=bash
# OCI provider: GPU bare-metal shapes.
# Environment:
#   OCI_COMPARTMENT    compartment OCID (required)
#   OCI_SHAPE          override the topology -> shape map
#   OCI_SUBNET         subnet OCID (default: first subnet in the compartment)
#   OCI_IMAGE          image OCID (default: latest Canonical Ubuntu 24.04 lookup)
#   OCI_AD             availability domain (default: first in the compartment)
# Notes: OCI sells GPU hosts as 8-GPU bare-metal shapes; only those
# topologies are mapped. Anything else requires OCI_SHAPE.
OCI_COMPARTMENT="${OCI_COMPARTMENT:-}"
SSH_USER="${SSH_USER:-ubuntu}"

provider_help() {
  cat <<'EOF'
OCI environment:
  OCI_COMPARTMENT, OCI_SHAPE, OCI_SUBNET, OCI_IMAGE, OCI_AD, SSH_KEY
The instance gets a public IP and uses ${SSH_KEY}.pub for SSH. Subnet
security lists must already allow TCP 22 plus NodePorts 30001-30006.
EOF
}

resolve_instance_type() {
  local gpu="$1" count="$2"
  if [[ -n "${OCI_SHAPE:-}" ]]; then
    INSTANCE_TYPE="$OCI_SHAPE"
    return
  fi
  if ((count != 8)); then
    die "OCI GPU hosts are 8-GPU bare metal; set OCI_SHAPE for a custom shape"
  fi
  case "$gpu" in
    a100-80gb) INSTANCE_TYPE="BM.GPU4.A100.8" ;;
    h100-80gb) INSTANCE_TYPE="BM.GPU.H100.8" ;;
    h200) INSTANCE_TYPE="BM.GPU.H200.8" ;;
    b200) INSTANCE_TYPE="BM.GPU.B200.8" ;;
    *) die "no default OCI shape for ${gpu} x ${count}; set OCI_SHAPE" ;;
  esac
  log "shape: ${INSTANCE_TYPE}"
}

provision() {
  have oci || die "install and configure the OCI CLI"
  [[ -n "$OCI_COMPARTMENT" ]] || die "set OCI_COMPARTMENT"
  require_pub_key

  local ad subnet image
  ad="${OCI_AD:-$(oci iam availability-domain list \
    --compartment-id "$OCI_COMPARTMENT" --query 'data[0].name' --output text)}"
  [[ -n "$ad" ]] || die "could not resolve an availability domain; set OCI_AD"

  subnet="${OCI_SUBNET:-$(oci network subnet list \
    --compartment-id "$OCI_COMPARTMENT" --query 'data[0].id' --output text)}"
  [[ -n "$subnet" ]] || die "no subnet in the compartment; set OCI_SUBNET"

  image="${OCI_IMAGE:-$(oci compute image list \
    --compartment-id "$OCI_COMPARTMENT" \
    --operating-system 'Canonical Ubuntu' \
    --operating-system-version '24.04' \
    --sort-by TIMECREATED --sort-order DESC \
    --query 'data[0].id' --output text)}"
  [[ -n "$image" ]] || die "could not resolve the Ubuntu image; set OCI_IMAGE"

  log "launching ${INSTANCE_TYPE} in ${ad} (this can take a while for bare metal)"
  local instance_id
  instance_id="$(oci compute instance launch \
    --compartment-id "$OCI_COMPARTMENT" \
    --availability-domain "$ad" \
    --display-name "$INSTANCE_NAME" \
    --shape "$INSTANCE_TYPE" \
    --subnet-id "$subnet" \
    --image-id "$image" \
    --assign-public-ip true \
    --ssh-authorized-keys-file "${SSH_KEY}.pub" \
    --wait-for-state RUNNING \
    --query 'data.id' --output text)"

  SSH_HOST="$(oci compute instance list-vnics \
    --instance-id "$instance_id" --query 'data[0]."public-ip"' --output text)"
  [[ -n "$SSH_HOST" ]] || die "instance has no public IP; use --instance-ip to continue"
  log "instance running at ${SSH_HOST}"
}
