# shellcheck shell=bash
# GCP provider: Compute Engine GPU instances.
# Environment:
#   GCP_PROJECT         project (default: gcloud config project)
#   GCP_ZONE            zone (default: gcloud config compute/zone; required)
#   GCP_MACHINE_TYPE    override the topology -> machine type map
#   GCP_IMAGE_FAMILY    OS image family (default ubuntu-2204-lts-amd64)
#   GCP_IMAGE_PROJECT   OS image project (default ubuntu-os-cloud)
#   GCP_NETWORK         VPC network (default default)
#   DISK_GB             boot disk size (default 1024)
# Notes: drivers are installed by the ol-runbook installer's Compute Engine
# path, so a plain Ubuntu image is enough. Only topologies GCP actually sells
# are mapped; anything else requires GCP_MACHINE_TYPE.
GCP_PROJECT="${GCP_PROJECT:-$(gcloud config get-value project 2>/dev/null || true)}"
GCP_ZONE="${GCP_ZONE:-$(gcloud config get-value compute/zone 2>/dev/null || true)}"
DISK_GB="${DISK_GB:-1024}"
SSH_USER="${SSH_USER:-ubuntu}"
GCP_IMAGE_FAMILY="${GCP_IMAGE_FAMILY:-ubuntu-2204-lts-amd64}"
GCP_IMAGE_PROJECT="${GCP_IMAGE_PROJECT:-ubuntu-os-cloud}"
GCP_NETWORK="${GCP_NETWORK:-default}"

provider_help() {
  cat <<'EOF'
GCP environment:
  GCP_PROJECT, GCP_ZONE, GCP_MACHINE_TYPE, GCP_IMAGE_FAMILY,
  GCP_IMAGE_PROJECT, GCP_NETWORK, DISK_GB, SSH_USER
The instance is created with the sl-worker tag and a matching firewall rule
opens TCP 22 plus NodePorts 30001-30006.
EOF
}

resolve_instance_type() {
  local gpu="$1" count="$2"
  if [[ -n "${GCP_MACHINE_TYPE:-}" ]]; then
    INSTANCE_TYPE="$GCP_MACHINE_TYPE"
    return
  fi
  case "${gpu}-${count}" in
    l4-1) INSTANCE_TYPE="g2-standard-24" ;;
    a100-80gb-1) INSTANCE_TYPE="a2-ultragpu-1g" ;;
    a100-80gb-2) INSTANCE_TYPE="a2-ultragpu-2g" ;;
    a100-80gb-4) INSTANCE_TYPE="a2-ultragpu-4g" ;;
    a100-80gb-8) INSTANCE_TYPE="a2-ultragpu-8g" ;;
    h100-80gb-1) INSTANCE_TYPE="a3-highgpu-1g" ;;
    h100-80gb-2) INSTANCE_TYPE="a3-highgpu-2g" ;;
    h100-80gb-4) INSTANCE_TYPE="a3-highgpu-4g" ;;
    h100-80gb-8) INSTANCE_TYPE="a3-highgpu-8g" ;;
    h200-8) INSTANCE_TYPE="a3-ultragpu-8g" ;;
    b200-8) INSTANCE_TYPE="a4-megagpu-1g" ;;
    *)
      die "no default GCP machine type for ${gpu} x ${count}; set GCP_MACHINE_TYPE"
      ;;
  esac
  log "machine type: ${INSTANCE_TYPE}"
}

provision() {
  have gcloud || die "install and configure the Google Cloud CLI"
  [[ -n "$GCP_PROJECT" ]] || die "set GCP_PROJECT (or run: gcloud config set project)"
  [[ -n "$GCP_ZONE" ]] || die "set GCP_ZONE (or run: gcloud config set compute/zone)"

  if ! gcloud compute firewall-rules describe sl-worker-ports \
    --project "$GCP_PROJECT" >/dev/null 2>&1; then
    log "creating firewall rule sl-worker-ports (SSH + NodePorts)"
    gcloud compute firewall-rules create sl-worker-ports \
      --project "$GCP_PROJECT" \
      --network "$GCP_NETWORK" \
      --allow tcp:22,tcp:30001-30006 \
      --source-ranges 0.0.0.0/0 \
      --target-tags sl-worker >/dev/null
  fi

  gcloud compute instances create "$INSTANCE_NAME" \
    --project "$GCP_PROJECT" \
    --zone "$GCP_ZONE" \
    --machine-type "$INSTANCE_TYPE" \
    --image-family "$GCP_IMAGE_FAMILY" \
    --image-project "$GCP_IMAGE_PROJECT" \
    --boot-disk-size "${DISK_GB}GB" \
    --network "$GCP_NETWORK" \
    --tags sl-worker \
    --maintenance-policy TERMINATE \
    --restart-on-failure >/dev/null

  SSH_HOST="$(gcloud compute instances describe "$INSTANCE_NAME" \
    --project "$GCP_PROJECT" --zone "$GCP_ZONE" \
    --format 'get(networkInterfaces[0].accessConfigs[0].natIP)')"
  [[ -n "$SSH_HOST" ]] || die "instance has no external IP; check the network or use --instance-ip"
  log "instance running at ${SSH_HOST}"
}

if [[ -z "${INSTANCE_IP_FLAG:-}" ]]; then
  remote_run() {
    gcloud compute ssh "$INSTANCE_NAME" \
      --project "$GCP_PROJECT" --zone "$GCP_ZONE" \
      --command "$*" -- -o StrictHostKeyChecking=accept-new
  }

  remote_interactive() {
    gcloud compute ssh "$INSTANCE_NAME" \
      --project "$GCP_PROJECT" --zone "$GCP_ZONE" \
      --command "$*" -- -tt
  }

  remote_copy() {
    gcloud compute scp --project "$GCP_PROJECT" --zone "$GCP_ZONE" \
      -- "$1" "${INSTANCE_NAME}:$2"
  }
fi
