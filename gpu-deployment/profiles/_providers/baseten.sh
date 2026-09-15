# shellcheck shell=bash
# Baseten uses a platform-specific Truss/custom-server configuration.
# Native configs live in ../baseten and are selected explicitly: their model
# variants and launch settings do not necessarily match a Helm profile.
# Container SSH is not the host required by the shared k3s installer.
SSH_USER="${SSH_USER:-root}"

provider_help() {
  cat <<'EOF'
Baseten environment:
  Baseten CLI login plus the secrets referenced in the selected Truss config.
Native configurations and a push helper are available in baseten/ beside
profiles/. Choose that configuration explicitly; it may differ from this
Helm profile in precision, speculative decoding, or GPU count.
The SSH/k3s path (--instance-ip) does not apply.
Documentation: https://docs.baseten.co/development/model/custom-server
EOF
  printf '\nList native configs: %s/../baseten/deploy.sh --list\n' "$SCRIPT_DIR"
}

resolve_instance_type() {
  # The native config, not this Helm profile, declares Baseten GPU resources.
  return 0
}

provision() {
  cat >&2 <<EOF
[deploy] Baseten steps:
[deploy]   1. List the copied Truss configurations:
[deploy]      ${SCRIPT_DIR}/../baseten/deploy.sh --list
[deploy]   2. Review the chosen config and preview its command:
[deploy]      ${SCRIPT_DIR}/../baseten/deploy.sh <config-name> --dry-run
[deploy]   3. Follow ${SCRIPT_DIR}/../baseten/README.md for secrets and push.
[deploy]      Config selection is independent of Helm profile ${PROFILE}.
EOF
  die "select a native Baseten configuration with baseten/deploy.sh"
}
