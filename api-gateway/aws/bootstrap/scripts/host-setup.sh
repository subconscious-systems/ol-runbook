#!/usr/bin/env bash
# Idempotent Docker agent host setup (AL2023). Safe to re-run via cloud-init or SSM.
set -euo pipefail

STATUS_DIR=/opt/api-gateway-infra
COMPOSE_VERSION="${COMPOSE_VERSION:-v2.32.4}"
KUBECTL_VERSION="${KUBECTL_VERSION:-v1.32.13}"
COMPOSE_PLUGIN=/usr/libexec/docker/cli-plugins/docker-compose

mkdir -p "${STATUS_DIR}"
log() {
  echo "[host-setup] $*" | tee -a "${STATUS_DIR}/setup.log"
  echo "$*" >"${STATUS_DIR}/status"
}

log "starting"
systemctl enable --now amazon-ssm-agent || true

# AL2023 ships curl-minimal (provides `curl`); do not install the `curl`
# package — it conflicts with curl-minimal.
if ! command -v docker >/dev/null 2>&1; then
  log "installing-docker"
  dnf install -y docker jq ca-certificates
else
  log "docker-present"
  dnf install -y jq ca-certificates >/dev/null 2>&1 || true
fi
command -v curl >/dev/null 2>&1 || {
  echo "ERROR: curl not found (expected curl-minimal on AL2023)" >&2
  exit 1
}
systemctl enable --now docker
usermod -aG docker ec2-user || true

need_compose=0
if [[ ! -x "${COMPOSE_PLUGIN}" ]]; then
  need_compose=1
elif ! docker compose version >/dev/null 2>&1; then
  need_compose=1
fi

if [[ "${need_compose}" -eq 1 ]]; then
  log "installing-compose"
  mkdir -p "$(dirname "${COMPOSE_PLUGIN}")"
  curl -fsSL "https://github.com/docker/compose/releases/download/${COMPOSE_VERSION}/docker-compose-linux-x86_64" \
    -o "${COMPOSE_PLUGIN}"
  chmod +x "${COMPOSE_PLUGIN}"
else
  log "compose-present"
fi

docker compose version

installed_kubectl_version=""
if command -v kubectl >/dev/null 2>&1; then
  installed_kubectl_version="$(kubectl version --client --output=json 2>/dev/null \
    | jq -r '.clientVersion.gitVersion // empty')"
fi
if [[ "${installed_kubectl_version}" != "${KUBECTL_VERSION}" ]]; then
  log "installing-kubectl-${KUBECTL_VERSION}"
  curl -fsSL "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl" \
    -o /usr/local/bin/kubectl
  chmod +x /usr/local/bin/kubectl
else
  log "kubectl-${KUBECTL_VERSION}-present"
fi
kubectl version --client --output=yaml >/dev/null

log "ready"
echo "docker-agent-host ready $(date -Is)" >"${STATUS_DIR}/bootstrap-ready"
