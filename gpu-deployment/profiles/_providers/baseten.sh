# shellcheck shell=bash
# Baseten provider: dedicated GPU deployments.
# Baseten does not expose raw GPU VMs; dedicated deployments run container
# images on dedicated GPU hardware and expose SSH into the running container
# (see Baseten's dedicated deployment docs for the current SSH path).
# Environment:
#   SSH_USER   default root (used with --instance-ip)
#   SSH_PORT   default 22 (used with --instance-ip)
# Notes: the GLM profiles' SGLang flags already track the tested Baseten
# deployment (Braintree-2). The k3s bootstrap below only applies when the SSH
# target is a general-purpose host; on Baseten-hosted containers, run the
# profile's worker image directly in the dedicated deployment.
SSH_USER="${SSH_USER:-root}"

provider_help() {
  cat <<'EOF'
Baseten environment:
  SSH_KEY, SSH_USER, SSH_PORT
Provisioning is manual: create a dedicated deployment with GPUs matching
the profile topology, using the worker image and flags from the profile's
values.yaml. If Baseten SSH exposes a general-purpose host, continue with:
  ./deploy.sh --instance-ip <host>
EOF
}

resolve_instance_type() {
  # No scripted provisioning: the GPU type/count is selected while creating
  # the dedicated deployment in the Baseten console.
  return 0
}

provision() {
  cat >&2 <<EOF
[deploy] Baseten steps:
[deploy]   1. Baseten console (or API): create a dedicated deployment with
[deploy]      ${GPU} x ${GPU_COUNT} GPUs matching the profile's values.yaml
[deploy]      (worker image, served model, and SGLang flags).
[deploy]   2. Baseten runs the worker image directly on dedicated hardware;
[deploy]      the k3s bootstrap only applies to a general-purpose SSH host.
[deploy]   3. To continue on an SSH-exposed host:
[deploy]      ./deploy.sh --instance-ip <host>
EOF
  die "automatic provisioning is not implemented for baseten"
}
