# shellcheck shell=bash
# Together AI provider: dedicated GPU instances on Together GPU Cloud.
# Environment:
#   SSH_USER   default ubuntu (used with --instance-ip)
#   SSH_PORT   default 22 (used with --instance-ip)
# Notes: Together GPU Cloud instances are created in their console with
# account SSH keys; no stable provisioning CLI/API is scripted here. Follow
# their GPU cluster docs for instance creation, then continue here.
SSH_USER="${SSH_USER:-ubuntu}"

provider_help() {
  cat <<'EOF'
Together AI environment:
  SSH_KEY, SSH_USER, SSH_PORT
Provisioning is manual: launch an instance matching the profile topology in
the Together GPU Cloud console with an account SSH key, then continue with:
  ./deploy.sh --instance-ip <instance-public-ip>
EOF
}

resolve_instance_type() {
  # No scripted provisioning: instance flavors are selected in the Together
  # GPU Cloud console.
  return 0
}

provision() {
  cat >&2 <<EOF
[deploy] Together AI steps:
[deploy]   1. Together GPU Cloud console: launch an instance with
[deploy]      ${GPU} x ${GPU_COUNT} GPUs and an account SSH key.
[deploy]   2. Continue here:
[deploy]      ./deploy.sh --instance-ip <instance-public-ip>
EOF
  die "automatic provisioning is not implemented for together"
}
