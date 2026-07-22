#!/usr/bin/env bash
# Bootstrap a GPU host for SGLang workers on Debian or Ubuntu:
#   packages → NVIDIA drivers (if needed) → container toolkit → k3s → kubectl →
#   NVIDIA RuntimeClass + device plugin.
#
# Run once on the GPU machine, then deploy from Distr (paste profiles/*.yaml).
#
# Usage:
#   ./dependencies.sh
#
# Optional env:
#   NAMESPACE=sglang              # default; same for all profiles and Distr steps
#   SKIP_NVIDIA_DRIVERS=false
#   K3S_VERSION=                  # empty = get.k3s.io default
#   NVIDIA_DEVICE_PLUGIN_URL=https://raw.githubusercontent.com/NVIDIA/k8s-device-plugin/main/deployments/static/nvidia-device-plugin.yml
#   GPU_READY_TIMEOUT_SECONDS=180
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKIP_NVIDIA_DRIVERS="${SKIP_NVIDIA_DRIVERS:-false}"
K3S_VERSION="${K3S_VERSION:-}"
K3S_KUBECONFIG_SOURCE="${K3S_KUBECONFIG_SOURCE:-/etc/rancher/k3s/k3s.yaml}"
NVIDIA_DEVICE_PLUGIN_URL="${NVIDIA_DEVICE_PLUGIN_URL:-https://raw.githubusercontent.com/NVIDIA/k8s-device-plugin/main/deployments/static/nvidia-device-plugin.yml}"
GPU_READY_TIMEOUT_SECONDS="${GPU_READY_TIMEOUT_SECONDS:-180}"
NAMESPACE="${NAMESPACE:-sglang}"

log() { printf '[dep] %s\n' "$*"; }
die() { printf '[dep] ERROR: %s\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

usage() {
  cat <<'EOF'
Usage: ./dependencies.sh

Install GPU host dependencies (drivers, k3s, NVIDIA device plugin).
Creates namespace sglang (override with NAMESPACE=...) for the Distr agent
and Helm Apply — same namespace for every profile.

Model weights and the worker image are downloaded by Distr Helm Apply.
EOF
}

while (($#)); do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    *)
      printf 'ERROR: unknown argument: %s\n' "$1" >&2
      usage >&2
      exit 1
      ;;
  esac
  shift
done

if [[ ! -r /etc/os-release ]]; then
  die "requires Debian/Ubuntu with /etc/os-release"
fi
# shellcheck disable=SC1091
source /etc/os-release
if [[ ! "${ID:-}" =~ ^(debian|ubuntu)$ ]] || ! have apt-get; then
  die "supports Debian/Ubuntu with apt only (found ${PRETTY_NAME:-unknown})"
fi

if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
  SUDO=()
  TARGET_USER="${SUDO_USER:-}"
else
  have sudo || die "sudo is required when not run as root"
  SUDO=(sudo)
  TARGET_USER="${USER:-$(id -un)}"
fi

run_as_root() {
  if [[ "${#SUDO[@]}" -eq 0 ]]; then
    "$@"
  else
    "${SUDO[@]}" "$@"
  fi
}

kubectl_cmd() {
  if have kubectl && [[ -r "${KUBECONFIG:-$K3S_KUBECONFIG_SOURCE}" || -r "$K3S_KUBECONFIG_SOURCE" ]]; then
    if [[ -n "${KUBECONFIG:-}" ]]; then
      kubectl "$@"
    elif [[ -r "$K3S_KUBECONFIG_SOURCE" ]]; then
      KUBECONFIG="$K3S_KUBECONFIG_SOURCE" kubectl "$@"
    else
      run_as_root k3s kubectl "$@"
    fi
  else
    run_as_root k3s kubectl "$@"
  fi
}

cat <<EOF
[dep] Will ensure:
  1. Base packages (curl, ca-certificates, gnupg, docker)
  2. NVIDIA host drivers via Google cuda_installer.pyz (if nvidia-smi missing; may reboot)
  3. NVIDIA Container Toolkit (Docker + k3s/containerd)
  4. k3s
  5. kubectl (+ kubeconfig for the current user)
  6. NVIDIA RuntimeClass + device plugin (nvidia.com/gpu)
  7. Namespace ${NAMESPACE} (Distr agent + Apply)
EOF

ensure_base_packages() {
  log "installing base packages"
  run_as_root apt-get update
  run_as_root apt-get install -y ca-certificates curl gnupg docker.io
  run_as_root systemctl enable --now docker || true
  if [[ -n "${TARGET_USER}" ]] && id "${TARGET_USER}" >/dev/null 2>&1; then
    if ! id -nG "${TARGET_USER}" | tr ' ' '\n' | grep -qx docker; then
      run_as_root usermod -aG docker "${TARGET_USER}"
      log "added ${TARGET_USER} to docker group (re-login may be needed for non-sudo docker)"
    fi
  fi
}

CUDA_INSTALLER_URL="${CUDA_INSTALLER_URL:-https://storage.googleapis.com/compute-gpu-installation-us/installer/latest/cuda_installer.pyz}"
CUDA_INSTALLER_PATH="${CUDA_INSTALLER_PATH:-/tmp/cuda_installer.pyz}"
CUDA_INSTALLER_WORKDIR="${CUDA_INSTALLER_WORKDIR:-/opt/google/cuda-installer}"

ensure_nvidia_drivers() {
  if [[ "${SKIP_NVIDIA_DRIVERS}" == "true" ]]; then
    log "SKIP_NVIDIA_DRIVERS=true; not installing host drivers"
    return
  fi
  if have nvidia-smi && nvidia-smi >/dev/null 2>&1; then
    log "nvidia-smi OK — skipping host driver install"
    nvidia-smi -L || true
    return
  fi

  log "nvidia-smi missing/broken — installing NVIDIA drivers via Google cuda_installer"
  have python3 || {
    run_as_root apt-get update
    run_as_root apt-get install -y python3
  }
  curl -fsSL "${CUDA_INSTALLER_URL}" -o "${CUDA_INSTALLER_PATH}"

  if [[ -f "${CUDA_INSTALLER_WORKDIR}/add_nvidia_repo" ]]; then
    if ! apt-cache show cuda-drivers >/dev/null 2>&1; then
      log "stale cuda_installer repo marker without cuda-drivers — repairing"
      run_as_root rm -f "${CUDA_INSTALLER_WORKDIR}/add_nvidia_repo"
      if [[ -f "${CUDA_INSTALLER_WORKDIR}/cuda-keyring_1.1-1_all.deb" ]]; then
        run_as_root dpkg -i "${CUDA_INSTALLER_WORKDIR}/cuda-keyring_1.1-1_all.deb" || true
        run_as_root apt-get update || true
      fi
    fi
  fi

  local -a installer_args=(install_driver)
  if ! apt-cache show cuda-drivers >/dev/null 2>&1; then
    log "cuda-drivers not in apt yet; using --installation-mode=binary"
    installer_args+=(--installation-mode=binary)
  fi

  log "running: python3 ${CUDA_INSTALLER_PATH} ${installer_args[*]}"
  if ! run_as_root python3 "${CUDA_INSTALLER_PATH}" "${installer_args[@]}"; then
    cat >&2 <<EOF
[dep] cuda_installer install_driver exited non-zero (reboot may be required).
Then reboot if asked and rerun: ./dependencies.sh
EOF
    exit 2
  fi

  if ! have nvidia-smi || ! nvidia-smi >/dev/null 2>&1; then
    cat >&2 <<EOF
[dep] Drivers installed but nvidia-smi is not usable yet.
Reboot, then rerun: sudo reboot && ./dependencies.sh
EOF
    exit 2
  fi
  log "nvidia-smi OK after driver install"
  nvidia-smi -L || true
}

ensure_nvidia_container_toolkit() {
  if have nvidia-ctk && have nvidia-container-runtime; then
    log "NVIDIA Container Toolkit already installed"
  else
    log "installing NVIDIA Container Toolkit"
    curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey |
      run_as_root gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
    curl -fsSL https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list |
      sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' |
      run_as_root tee /etc/apt/sources.list.d/nvidia-container-toolkit.list >/dev/null
    run_as_root apt-get update
    run_as_root apt-get install -y nvidia-container-toolkit
  fi

  if have docker; then
    log "configuring NVIDIA runtime for Docker"
    run_as_root nvidia-ctk runtime configure --runtime=docker
    run_as_root systemctl restart docker
  fi
}

ensure_k3s() {
  if have k3s; then
    log "k3s already installed"
    if have systemctl && ! systemctl is-active --quiet k3s; then
      log "starting k3s"
      run_as_root systemctl start k3s
    fi
    return
  fi
  log "installing k3s"
  local env_args=(INSTALL_K3S_EXEC="--write-kubeconfig-mode 644")
  if [[ -n "${K3S_VERSION}" ]]; then
    env_args+=(INSTALL_K3S_VERSION="${K3S_VERSION}")
  fi
  if [[ "${#SUDO[@]}" -gt 0 ]]; then
    curl -sfL https://get.k3s.io | run_as_root env "${env_args[@]}" sh -
  else
    curl -sfL https://get.k3s.io | env "${env_args[@]}" sh -
  fi
}

wait_k3s_api() {
  local elapsed=0
  log "waiting for k3s API"
  while (( elapsed < 120 )); do
    if run_as_root k3s kubectl get --raw=/readyz >/dev/null 2>&1; then
      log "k3s API ready"
      return
    fi
    sleep 2
    elapsed=$((elapsed + 2))
  done
  die "timed out waiting for k3s API (try: systemctl status k3s)"
}

ensure_kubectl() {
  if have kubectl; then
    log "kubectl already installed: $(kubectl version --client --short 2>/dev/null || kubectl version --client 2>/dev/null | head -1)"
  else
    log "installing kubectl"
    local arch version url tmp
    arch="$(uname -m)"
    case "$arch" in
      x86_64 | amd64) arch=amd64 ;;
      aarch64 | arm64) arch=arm64 ;;
      *) die "unsupported architecture for kubectl: $arch" ;;
    esac
    version="$(curl -fsSL https://dl.k8s.io/release/stable.txt)"
    url="https://dl.k8s.io/release/${version}/bin/linux/${arch}/kubectl"
    tmp="$(mktemp)"
    curl -fsSL "$url" -o "$tmp"
    run_as_root install -m 0755 "$tmp" /usr/local/bin/kubectl
    rm -f "$tmp"
    log "installed kubectl ${version}"
  fi

  if [[ -f "$K3S_KUBECONFIG_SOURCE" ]]; then
    local dest="${KUBECONFIG:-$HOME/.kube/config}"
    if [[ "${EUID:-$(id -u)}" -eq 0 && -n "${TARGET_USER}" ]]; then
      local home
      home="$(getent passwd "${TARGET_USER}" | cut -d: -f6 || true)"
      if [[ -n "$home" ]]; then
        dest="${home}/.kube/config"
      fi
    fi
    mkdir -p "$(dirname "$dest")" 2>/dev/null || run_as_root mkdir -p "$(dirname "$dest")"
    if [[ -r "$K3S_KUBECONFIG_SOURCE" ]]; then
      cp "$K3S_KUBECONFIG_SOURCE" "$dest"
    else
      run_as_root cp "$K3S_KUBECONFIG_SOURCE" "$dest"
      if [[ -n "${TARGET_USER}" ]]; then
        run_as_root chown "${TARGET_USER}:${TARGET_USER}" "$dest" 2>/dev/null ||
          run_as_root chown "${TARGET_USER}" "$dest" || true
      fi
    fi
    chmod 600 "$dest" 2>/dev/null || run_as_root chmod 600 "$dest"
    if have kubectl; then
      KUBECONFIG="$dest" kubectl config set-cluster default --server=https://127.0.0.1:6443 >/dev/null 2>&1 || true
    fi
    log "kubeconfig written to ${dest}"
    export KUBECONFIG="$dest"
  fi
}

configure_k3s_nvidia_runtime() {
  have nvidia-ctk || die "nvidia-ctk missing after toolkit install"
  log "configuring NVIDIA default runtime for k3s"
  run_as_root mkdir -p /etc/rancher/k3s/config.yaml.d
  printf '%s\n' 'default-runtime: nvidia' |
    run_as_root tee /etc/rancher/k3s/config.yaml.d/90-nvidia-runtime.yaml >/dev/null

  if [[ -f /var/lib/rancher/k3s/agent/etc/containerd/config.toml ]]; then
    run_as_root nvidia-ctk runtime configure \
      --runtime=containerd \
      --config=/var/lib/rancher/k3s/agent/etc/containerd/config.toml || true
  fi

  log "restarting k3s for NVIDIA runtime"
  run_as_root systemctl restart k3s
  sleep 5
  wait_k3s_api
}

apply_nvidia_device_plugin() {
  local gpu_count
  gpu_count="$(
    kubectl_cmd get nodes \
      -o jsonpath='{range .items[*]}{.status.allocatable.nvidia\.com/gpu}{"\n"}{end}' \
      2>/dev/null |
      awk 'NF {sum += $1} END {print sum + 0}'
  )"
  if (( gpu_count > 0 )); then
    log "already ${gpu_count} allocatable nvidia.com/gpu; skipping device plugin apply"
  else
    log "applying NVIDIA device plugin"
    if ! kubectl_cmd apply -f "${NVIDIA_DEVICE_PLUGIN_URL}"; then
      if kubectl_cmd -n kube-system get daemonset nvidia-device-plugin-daemonset >/dev/null 2>&1 ||
        kubectl_cmd -n kube-system get daemonset nvidia-device-plugin-ds >/dev/null 2>&1; then
        log "device plugin apply failed but DaemonSet exists; continuing"
      else
        die "failed to apply device plugin from ${NVIDIA_DEVICE_PLUGIN_URL}"
      fi
    fi
  fi

  kubectl_cmd apply -f - <<'EOF'
apiVersion: node.k8s.io/v1
kind: RuntimeClass
metadata:
  name: nvidia
handler: nvidia
EOF

  kubectl_cmd -n kube-system patch daemonset nvidia-device-plugin-daemonset \
    --type=strategic \
    -p '{"spec":{"template":{"spec":{"runtimeClassName":"nvidia","containers":[{"name":"nvidia-device-plugin-ctr","env":[{"name":"NVIDIA_VISIBLE_DEVICES","value":"all"},{"name":"NVIDIA_DRIVER_CAPABILITIES","value":"utility,compute"}]}]}}}}' \
    >/dev/null 2>&1 || true
  kubectl_cmd -n kube-system rollout restart daemonset/nvidia-device-plugin-daemonset >/dev/null 2>&1 || true
  kubectl_cmd -n kube-system rollout status daemonset/nvidia-device-plugin-daemonset --timeout=120s >/dev/null 2>&1 || true
}

wait_nvidia_gpu_allocatable() {
  local elapsed=0 gpu_count
  log "waiting for nvidia.com/gpu allocatable"
  while (( elapsed < GPU_READY_TIMEOUT_SECONDS )); do
    gpu_count="$(
      kubectl_cmd get nodes \
        -o jsonpath='{range .items[*]}{.status.allocatable.nvidia\.com/gpu}{"\n"}{end}' \
        2>/dev/null |
        awk 'NF {sum += $1} END {print sum + 0}'
    )"
    if (( gpu_count > 0 )); then
      log "Kubernetes reports ${gpu_count} allocatable nvidia.com/gpu"
      return
    fi
    sleep 5
    elapsed=$((elapsed + 5))
  done
  die "timed out waiting for nvidia.com/gpu (check device-plugin pods in kube-system)"
}

ensure_deployment_namespace() {
  if [[ ! "${NAMESPACE}" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]]; then
    die "invalid NAMESPACE: ${NAMESPACE}"
  fi
  log "ensuring namespace ${NAMESPACE}"
  if kubectl_cmd get namespace "${NAMESPACE}" >/dev/null 2>&1; then
    log "namespace ${NAMESPACE} already exists"
  else
    kubectl_cmd create namespace "${NAMESPACE}"
    log "created namespace ${NAMESPACE}"
  fi
}

ensure_base_packages
ensure_nvidia_drivers
ensure_nvidia_container_toolkit
ensure_k3s
wait_k3s_api
ensure_kubectl
configure_k3s_nvidia_runtime
apply_nvidia_device_plugin
wait_nvidia_gpu_allocatable
ensure_deployment_namespace

cat <<EOF

[dep] Host bootstrap complete.
[dep] Namespace: ${NAMESPACE} (use this for Distr agent connect -n and Helm Apply)

Next — see ${SCRIPT_DIR}/README.md (steps 2–6).
EOF
