# shellcheck shell=bash
# Azure provider: GPU VMs with the NVIDIA driver VM extension.
# Environment:
#   AZ_RESOURCE_GROUP    resource group (required)
#   AZ_LOCATION         region (default eastus)
#   AZURE_VM_SIZE       override the topology -> VM size map
#   AZ_IMAGE            image URN (default Ubuntu 22.04 LTS)
#   DISK_GB             OS disk size (default 1024)
# Notes: only topologies Azure actually sells are mapped; anything else
# requires AZURE_VM_SIZE.
AZ_RESOURCE_GROUP="${AZ_RESOURCE_GROUP:-}"
AZ_LOCATION="${AZ_LOCATION:-eastus}"
DISK_GB="${DISK_GB:-1024}"
SSH_USER="${SSH_USER:-azureuser}"
AZ_IMAGE="${AZ_IMAGE:-Canonical:0001-com-ubuntu-server-jammy:22_04-lts-amd64:latest}"

provider_help() {
  cat <<'EOF'
Azure environment:
  AZ_RESOURCE_GROUP, AZ_LOCATION, AZURE_VM_SIZE, AZ_IMAGE, DISK_GB, SSH_KEY
The VM's public key is taken from ${SSH_KEY}.pub, and ports 22 plus
NodePorts 30001-30006 are opened. The Microsoft.HpcCompute
NvidiaGpuDriverLinuxExtension extension installs host drivers, so the
ol-runbook installer only adds container toolkit + k3s.
EOF
}

resolve_instance_type() {
  local gpu="$1" count="$2"
  if [[ -n "${AZURE_VM_SIZE:-}" ]]; then
    INSTANCE_TYPE="$AZURE_VM_SIZE"
    return
  fi
  case "${gpu}-${count}" in
    a100-80gb-1) INSTANCE_TYPE="Standard_NC24ads_A100_v4" ;;
    a100-80gb-2) INSTANCE_TYPE="Standard_NC48ads_A100_v4" ;;
    a100-80gb-4) INSTANCE_TYPE="Standard_NC96ads_A100_v4" ;;
    a100-80gb-8) INSTANCE_TYPE="Standard_ND96asr_v4" ;;
    h100-80gb-1) INSTANCE_TYPE="Standard_NC40ads_H100_v5" ;;
    h100-80gb-2) INSTANCE_TYPE="Standard_NC80ads_H100_v5" ;;
    h100-80gb-8) INSTANCE_TYPE="Standard_ND96isr_H100_v5" ;;
    h200-8) INSTANCE_TYPE="Standard_ND96isr_H200_v6" ;;
    *)
      die "no default Azure VM size for ${gpu} x ${count}; set AZURE_VM_SIZE"
      ;;
  esac
  log "VM size: ${INSTANCE_TYPE}"
}

provision() {
  have az || die "install and configure the Azure CLI"
  [[ -n "$AZ_RESOURCE_GROUP" ]] || die "set AZ_RESOURCE_GROUP (create one with: az group create -n <name> -l ${AZ_LOCATION})"
  require_pub_key

  az vm create \
    --resource-group "$AZ_RESOURCE_GROUP" \
    --name "$INSTANCE_NAME" \
    --location "$AZ_LOCATION" \
    --size "$INSTANCE_TYPE" \
    --image "$AZ_IMAGE" \
    --admin-username "$SSH_USER" \
    --ssh-key-values "$(cat "${SSH_KEY}.pub")" \
    --os-disk-size-gb "$DISK_GB" >/dev/null

  az vm open-port --resource-group "$AZ_RESOURCE_GROUP" --name "$INSTANCE_NAME" \
    --port 22 --priority 900 >/dev/null
  az vm open-port --resource-group "$AZ_RESOURCE_GROUP" --name "$INSTANCE_NAME" \
    --port 30001-30006 --priority 901 >/dev/null

  log "installing the NVIDIA driver VM extension"
  az vm extension set \
    --resource-group "$AZ_RESOURCE_GROUP" \
    --vm-name "$INSTANCE_NAME" \
    --name NvidiaGpuDriverLinuxExtension \
    --publisher Microsoft.HpcCompute \
    --settings '{}' >/dev/null

  SSH_HOST="$(az vm show --show-details \
    --resource-group "$AZ_RESOURCE_GROUP" --name "$INSTANCE_NAME" \
    --query publicIps -o tsv)"
  [[ -n "$SSH_HOST" ]] || die "VM has no public IP; use --instance-ip to continue"
  log "VM running at ${SSH_HOST}"
}
