#!/usr/bin/env bash
# Idempotent Ubuntu 24.04 setup for the keyless GCE Docker-agent host.
# No credentials or Distr connect material is written by this script.
set -euo pipefail

STATUS_DIR="/opt/api-gateway-infra"
GOOGLE_KEYRING="/etc/apt/keyrings/cloud.google.gpg"
GOOGLE_APT_SOURCE="/etc/apt/sources.list.d/google-cloud-sdk.list"

export DEBIAN_FRONTEND=noninteractive

install -d -m 0755 "${STATUS_DIR}" /etc/apt/keyrings

log() {
  printf '[host-setup] %s\n' "$*" | tee -a "${STATUS_DIR}/setup.log"
  printf '%s\n' "$*" >"${STATUS_DIR}/status"
}

log "starting"

apt-get update -y
apt-get install -y --no-install-recommends \
  ca-certificates \
  curl \
  docker.io \
  docker-compose-v2 \
  git \
  gnupg \
  jq \
  openssl

if [[ ! -s "${GOOGLE_KEYRING}" ]]; then
  log "installing-google-cloud-apt-key"
  curl --proto '=https' --tlsv1.2 -fsSL \
    https://packages.cloud.google.com/apt/doc/apt-key.gpg \
    | gpg --dearmor --yes -o "${GOOGLE_KEYRING}"
  chmod 0644 "${GOOGLE_KEYRING}"
fi

if [[ ! -s "${GOOGLE_APT_SOURCE}" ]]; then
  log "configuring-google-cloud-apt-repository"
  printf '%s\n' \
    "deb [signed-by=${GOOGLE_KEYRING}] https://packages.cloud.google.com/apt cloud-sdk main" \
    >"${GOOGLE_APT_SOURCE}"
fi

apt-get update -y
apt-get install -y --no-install-recommends \
  google-cloud-cli \
  google-cloud-cli-gke-gcloud-auth-plugin \
  kubectl

systemctl enable --now docker

docker version >/dev/null
docker compose version
gcloud version >/dev/null
gke-gcloud-auth-plugin --version >/dev/null
kubectl version --client --output=yaml >/dev/null
jq --version >/dev/null

cat >/etc/profile.d/gke-auth-plugin.sh <<'EOF'
export USE_GKE_GCLOUD_AUTH_PLUGIN=True
EOF
chmod 0644 /etc/profile.d/gke-auth-plugin.sh

log "ready"
printf 'docker-agent-host ready %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  >"${STATUS_DIR}/bootstrap-ready"
