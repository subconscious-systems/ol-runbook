# shellcheck shell=bash
# Fireworks AI provider: managed inference deployments.
# Fireworks serves models on managed GPU deployments; it does not provide
# raw GPU hosts or SSH access, so the Subconscious k3s worker flow does not
# apply. This wrapper prints the platform boundary and the manual path for
# serving the profile's model as a Fireworks deployment.
SSH_USER="${SSH_USER:-root}"

provider_help() {
  cat <<'EOF'
Fireworks AI environment:
  (none)
Fireworks runs managed deployments only: no raw GPU hosts and no SSH, so
neither provisioning nor --instance-ip applies. Use the Fireworks console to
serve the profile's model on dedicated GPUs as an external OpenAI-compatible
endpoint; it will not register as a Subconscious SGLang worker.
EOF
}

resolve_instance_type() {
  # No scripted provisioning and no SSH continuation: Fireworks deployments
  # are managed platform resources.
  return 0
}

provision() {
  cat >&2 <<EOF
[deploy] Fireworks AI steps:
[deploy]   1. Fireworks serves models on managed deployments (no raw GPU
[deploy]      hosts, no SSH); the Subconscious SGLang worker cannot run there.
[deploy]   2. To serve the profile's model externally, create a Fireworks
[deploy]      deployment with ${GPU} x ${GPU_COUNT}-class GPUs for the model
[deploy]      declared in the profile's values.yaml, then use its
[deploy]      OpenAI-compatible endpoint with the gateway separately.
EOF
  die "automatic provisioning is not implemented for fireworks"
}
