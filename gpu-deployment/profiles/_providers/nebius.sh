# shellcheck shell=bash
# Nebius provider: GPU instances on Nebius AI Cloud.
# Nebius resources are managed through the Nebius AI Cloud console or their
# Terraform provider; there is no stable CLI surface this script can drive.
# Provision the GPU host in the Nebius console/Terraform (matching the profile
# topology; their GPU platforms cover H100, H200, B200, and L40S), then run the
# profile's deploy.sh with --instance-ip to bootstrap, stage, and start the
# weight download on that host.
# Environment:
#   SSH_USER   default ubuntu
SSH_USER="${SSH_USER:-ubuntu}"

provider_help() {
  cat <<'EOF'
Nebius environment:
  SSH_KEY, SSH_USER
Provisioning is manual: create the GPU instance in the Nebius AI Cloud
console or with their Terraform provider, then continue with:
  ./deploy.sh --instance-ip <instance-public-ip>
Subnet security groups must allow TCP 22 plus NodePorts 30001-30006.
EOF
}

resolve_instance_type() {
  # No CLI-driven provisioning: the guided steps below select the flavor in
  # the Nebius console/Terraform instead of mapping it here.
  return 0
}

provision() {
  cat >&2 <<EOF
[deploy] Nebius steps:
[deploy]   1. Nebius AI Cloud console (or Terraform): create a ${GPU} x ${GPU_COUNT}
[deploy]      instance in a subnet whose security groups allow TCP 22 and
[deploy]      NodePorts 30001-30006.
[deploy]   2. Continue here:
[deploy]      ./deploy.sh --instance-ip <instance-public-ip>
EOF
  die "automatic provisioning is not implemented for nebius"
}
