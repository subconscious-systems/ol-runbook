# shellcheck shell=bash
# Baseten uses a platform-specific Truss/custom-server configuration.
# This helper has no Baseten deployment implementation. Container SSH is not
# the general-purpose host required by the shared k3s installer.
SSH_USER="${SSH_USER:-root}"

provider_help() {
  cat <<'EOF'
Baseten environment:
  No deployment configuration is consumed by this helper.
Use the Baseten Truss config supplied by your FDE. It must specify the
worker image, launch command, weights, GPU resources, and HTTP endpoints.
The SSH/k3s path (--instance-ip) does not apply.
Documentation: https://docs.baseten.co/development/model/custom-server
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
[deploy]   1. Obtain the current Truss config from your FDE for ${PROFILE}.
[deploy]   2. Verify its worker image, weights, launch flags, endpoints,
[deploy]      and ${GPU} x ${GPU_COUNT} GPU resources.
[deploy]   3. Deploy through Baseten's Truss flow, then verify the endpoint.
[deploy]      Do not run the k3s host installer inside a Baseten container.
EOF
  die "automatic provisioning is not implemented for baseten"
}
