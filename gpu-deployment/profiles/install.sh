#!/usr/bin/env bash
# Bootstrap a GPU host for SGLang workers on Debian, Ubuntu, Rocky, or RHEL:
#   packages → NVIDIA drivers (if needed) → container toolkit → k3s → kubectl →
#   NVIDIA RuntimeClass + device plugin.
#
# Run once on the GPU machine, then download weights with weights.sh and deploy
# from Distr using the YAML in this directory.
#
# Usage:
#   ./install.sh
#
# Optional env:
#   NAMESPACE=sglang              # default; same for all profiles and Distr steps
#   SKIP_NVIDIA_DRIVERS=false
#   K3S_VERSION=v1.36.0+k3s1     # pinned: avoids containerd 2.3 registry header timeout
#   NVIDIA_DEVICE_PLUGIN_URL=https://raw.githubusercontent.com/NVIDIA/k8s-device-plugin/v0.19.3/deployments/static/nvidia-device-plugin.yml
#   GPU_READY_TIMEOUT_SECONDS=180
#   K3S_FIREWALL_NODEPORTS=30001-30006  # Rocky/RHEL firewalld only
#   MODEL_STORAGE_PATHS=/models/hf:/mnt
set -euo pipefail

SKIP_NVIDIA_DRIVERS="${SKIP_NVIDIA_DRIVERS:-false}"
K3S_VERSION="${K3S_VERSION:-v1.36.0+k3s1}"
K3S_BIN="${K3S_BIN:-/usr/local/bin/k3s}"
K3S_KUBECONFIG_SOURCE="${K3S_KUBECONFIG_SOURCE:-/etc/rancher/k3s/k3s.yaml}"
NVIDIA_DEVICE_PLUGIN_URL="${NVIDIA_DEVICE_PLUGIN_URL:-https://raw.githubusercontent.com/NVIDIA/k8s-device-plugin/v0.19.3/deployments/static/nvidia-device-plugin.yml}"
GPU_READY_TIMEOUT_SECONDS="${GPU_READY_TIMEOUT_SECONDS:-180}"
NAMESPACE="${NAMESPACE:-sglang}"
K3S_FIREWALL_NODEPORTS="${K3S_FIREWALL_NODEPORTS:-30001-30006}"
K3S_POD_CIDR="${K3S_POD_CIDR:-10.42.0.0/16}"
K3S_SERVICE_CIDR="${K3S_SERVICE_CIDR:-10.43.0.0/16}"
MODEL_STORAGE_PATHS="${MODEL_STORAGE_PATHS:-/models/hf:/mnt}"

log() { printf '[dep] %s\n' "$*"; }
die() { printf '[dep] ERROR: %s\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

usage() {
  cat <<'EOF'
Usage: ./install.sh

Install GPU host dependencies (drivers, k3s, NVIDIA device plugin).
Creates namespace sglang (override with NAMESPACE=...) for the Distr agent
and Helm Apply — same namespace for every profile.

Model weights are downloaded separately from the selected profile directory
with ./weights.sh.
EOF
}

if (($#)); then
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
fi

if [[ ! -r /etc/os-release ]]; then
  die "requires a supported Linux distribution with /etc/os-release"
fi
# shellcheck disable=SC1091
source /etc/os-release
case "${ID:-}" in
  debian | ubuntu)
    have apt-get || die "apt-get is required on ${PRETTY_NAME:-Debian/Ubuntu}"
    PACKAGE_FAMILY=deb
    ;;
  rocky | rhel | centos | almalinux)
    have dnf || die "dnf is required on ${PRETTY_NAME:-Rocky/RHEL}"
    PACKAGE_FAMILY=rpm
    ;;
  *)
    die "supports Debian, Ubuntu, Rocky, RHEL, CentOS, and AlmaLinux (found ${PRETTY_NAME:-unknown})"
    ;;
esac

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
      run_as_root "$K3S_BIN" kubectl "$@"
    fi
  else
    run_as_root "$K3S_BIN" kubectl "$@"
  fi
}

cat <<EOF
[dep] Host: ${PRETTY_NAME:-unknown} (${PACKAGE_FAMILY})
[dep] Will ensure:
  1. Base packages (curl, ca-certificates, gnupg, docker, Python venv)
  2. NVIDIA host drivers (if nvidia-smi is missing; may require a reboot)
  3. NVIDIA Container Toolkit (Docker + k3s/containerd)
  4. k3s
  5. kubectl (+ kubeconfig for the current user)
  6. NVIDIA RuntimeClass + device plugin (nvidia.com/gpu)
  7. Namespace ${NAMESPACE} (Distr agent + Apply)
EOF

ensure_base_packages() {
  log "installing base packages"
  if [[ "$PACKAGE_FAMILY" == "deb" ]]; then
    run_as_root apt-get update
    run_as_root apt-get install -y ca-certificates curl gnupg docker.io python3 python3-venv
  else
    run_as_root dnf install -y \
      ca-certificates curl dnf-plugins-core gnupg2 python3-pip \
      python3.11 python3.11-pip \
      container-selinux policycoreutils-python-utils selinux-policy-targeted
    have python3 || die "the installed Rocky/RHEL Python packages did not provide python3"
    have python3.11 || die "the installed Rocky/RHEL Python packages did not provide python3.11"
    if ! have docker; then
      log "installing Docker CE"
      run_as_root dnf config-manager --add-repo \
        https://download.docker.com/linux/centos/docker-ce.repo
      run_as_root dnf install -y \
        docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    fi
  fi
  run_as_root systemctl enable --now docker || true
  if [[ -n "${TARGET_USER}" ]] && id "${TARGET_USER}" >/dev/null 2>&1; then
    if ! id -nG "${TARGET_USER}" | tr ' ' '\n' | grep -qx docker; then
      run_as_root usermod -aG docker "${TARGET_USER}"
      log "added ${TARGET_USER} to docker group (re-login may be needed for non-sudo docker)"
    fi
  fi
}

ensure_model_storage() {
  local model_path
  local -a model_paths
  IFS=: read -r -a model_paths <<<"$MODEL_STORAGE_PATHS"
  ((${#model_paths[@]} > 0)) || die "MODEL_STORAGE_PATHS must contain at least one absolute path"

  for model_path in "${model_paths[@]}"; do
    [[ "$model_path" == /* && "$model_path" != "/" ]] ||
      die "MODEL_STORAGE_PATHS entries must be absolute non-root paths"
    log "ensuring model storage at ${model_path}"
    if [[ ! -d "$model_path" ]]; then
      run_as_root install -d -m 0755 "$model_path"
      if [[ -n "${TARGET_USER}" ]] && id "${TARGET_USER}" >/dev/null 2>&1; then
        run_as_root chown "${TARGET_USER}" "$model_path"
      fi
    fi
  done
}

configure_rpm_model_selinux() {
  [[ "$PACKAGE_FAMILY" == "rpm" ]] || return
  have getenforce || return
  [[ "$(getenforce)" != "Disabled" ]] || return
  have semanage || die "semanage is required to label model storage for SELinux"
  have restorecon || die "restorecon is required to label model storage for SELinux"

  local model_path pattern
  local -a model_paths
  IFS=: read -r -a model_paths <<<"$MODEL_STORAGE_PATHS"
  for model_path in "${model_paths[@]}"; do
    pattern="${model_path}(/.*)?"
    log "allowing container read access to ${model_path} under SELinux"
    if ! run_as_root semanage fcontext -a -t container_file_t "$pattern"; then
      run_as_root semanage fcontext -m -t container_file_t "$pattern"
    fi
    run_as_root restorecon -RF "$model_path"
  done
}

CUDA_INSTALLER_URL="${CUDA_INSTALLER_URL:-https://storage.googleapis.com/compute-gpu-installation-us/installer/latest/cuda_installer.pyz}"
CUDA_INSTALLER_PATH="${CUDA_INSTALLER_PATH:-/tmp/cuda_installer.pyz}"
CUDA_INSTALLER_WORKDIR="${CUDA_INSTALLER_WORKDIR:-/opt/google/cuda-installer}"

install_debian_13_nvidia_drivers() {
  local repo_arch keyring
  case "$(uname -m)" in
    x86_64 | amd64) repo_arch=x86_64 ;;
    aarch64 | arm64) repo_arch=sbsa ;;
    *) die "unsupported Debian 13 architecture for NVIDIA drivers: $(uname -m)" ;;
  esac

  log "installing NVIDIA drivers from the official Debian 13 repository"
  run_as_root apt-get update
  run_as_root apt-get install -y "linux-headers-$(uname -r)"
  keyring="$(mktemp --suffix=.deb)"
  curl -fsSL \
    "https://developer.download.nvidia.com/compute/cuda/repos/debian13/${repo_arch}/cuda-keyring_1.1-1_all.deb" \
    -o "${keyring}"
  run_as_root dpkg -i "${keyring}"
  rm -f "${keyring}"
  run_as_root apt-get update
  run_as_root env DEBIAN_FRONTEND=noninteractive apt-get install -y nvidia-open
}

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

  if [[ "$PACKAGE_FAMILY" == "rpm" ]]; then
    die "nvidia-smi is missing or broken; install the NVIDIA host driver through the Rocky/RHEL image or vendor-supported driver path, reboot if required, then rerun ./install.sh"
  fi

  if [[ "${ID:-}" == "debian" && "${VERSION_ID%%.*}" == "13" ]]; then
    # Google cuda_installer can select the original Compute Engine image kernel
    # after apt has rotated its headers out of the mirror. Native DKMS packages
    # build against the running kernel and avoid that stale-version failure.
    install_debian_13_nvidia_drivers
    if ! have nvidia-smi || ! nvidia-smi >/dev/null 2>&1; then
      cat >&2 <<EOF
[dep] Drivers installed but nvidia-smi is not usable yet.
Reboot, then rerun: sudo reboot && ./install.sh
EOF
      exit 2
    fi
    log "nvidia-smi OK after driver install"
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
Then reboot if asked and rerun: ./install.sh
EOF
    exit 2
  fi

  if ! have nvidia-smi || ! nvidia-smi >/dev/null 2>&1; then
    cat >&2 <<EOF
[dep] Drivers installed but nvidia-smi is not usable yet.
Reboot, then rerun: sudo reboot && ./install.sh
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
    if [[ "$PACKAGE_FAMILY" == "deb" ]]; then
      curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey |
        run_as_root gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
      curl -fsSL https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list |
        sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' |
        run_as_root tee /etc/apt/sources.list.d/nvidia-container-toolkit.list >/dev/null
      run_as_root apt-get update
      run_as_root apt-get install -y nvidia-container-toolkit
    else
      curl -fsSL \
        https://nvidia.github.io/libnvidia-container/stable/rpm/nvidia-container-toolkit.repo |
        run_as_root tee /etc/yum.repos.d/nvidia-container-toolkit.repo >/dev/null
      run_as_root dnf clean expire-cache
      run_as_root dnf install -y nvidia-container-toolkit
    fi
  fi

  if have docker; then
    log "configuring NVIDIA runtime for Docker"
    run_as_root nvidia-ctk runtime configure --runtime=docker
    run_as_root systemctl restart docker
  fi
}

configure_rpm_firewalld() {
  [[ "$PACKAGE_FAMILY" == "rpm" ]] || return
  have firewall-cmd || return
  systemctl is-active --quiet firewalld || return

  local first_port last_port
  if [[ "$K3S_FIREWALL_NODEPORTS" =~ ^([0-9]+)-([0-9]+)$ ]]; then
    first_port="${BASH_REMATCH[1]}"
    last_port="${BASH_REMATCH[2]}"
  elif [[ "$K3S_FIREWALL_NODEPORTS" =~ ^[0-9]+$ ]]; then
    first_port="$K3S_FIREWALL_NODEPORTS"
    last_port="$K3S_FIREWALL_NODEPORTS"
  else
    die "K3S_FIREWALL_NODEPORTS must be one port or a range such as 30001-30006"
  fi
  if (( first_port < 30000 || last_port > 32767 || first_port > last_port )); then
    die "K3S_FIREWALL_NODEPORTS must stay within the Kubernetes NodePort range 30000-32767"
  fi

  log "configuring firewalld for k3s and NodePorts ${K3S_FIREWALL_NODEPORTS}"
  run_as_root firewall-cmd --permanent --add-port=6443/tcp
  run_as_root firewall-cmd --permanent --zone=trusted --add-source="$K3S_POD_CIDR"
  run_as_root firewall-cmd --permanent --zone=trusted --add-source="$K3S_SERVICE_CIDR"
  run_as_root firewall-cmd --permanent --add-port="${K3S_FIREWALL_NODEPORTS}/tcp"
  run_as_root firewall-cmd --reload
}

configure_k3s_cgroup_compat() {
  local cgroup_fs
  cgroup_fs="$(stat -fc %T /sys/fs/cgroup)"
  [[ "$cgroup_fs" == "tmpfs" ]] || return

  log "cgroup v1 detected; allowing the kubelet compatibility mode"
  run_as_root mkdir -p /etc/rancher/k3s/config.yaml.d
  printf '%s\n' \
    'kubelet-arg:' \
    '  - fail-cgroupv1=false' |
    run_as_root tee /etc/rancher/k3s/config.yaml.d/80-cgroup-v1.yaml >/dev/null
}

ensure_k3s() {
  local installed_version=""
  if [[ -x "$K3S_BIN" ]]; then
    installed_version="$("$K3S_BIN" --version | awk 'NR == 1 {print $3}')"
  fi
  if [[ -n "$installed_version" && "$installed_version" == "$K3S_VERSION" ]]; then
    log "k3s ${installed_version} already installed"
    log "restarting k3s to apply host configuration"
    run_as_root systemctl restart k3s
    return
  fi
  if [[ -n "$installed_version" ]]; then
    log "replacing k3s ${installed_version} with pinned ${K3S_VERSION}"
  else
    log "installing pinned k3s ${K3S_VERSION}"
  fi
  local k3s_exec="--write-kubeconfig-mode 644"
  if [[ "$PACKAGE_FAMILY" == "rpm" ]]; then
    k3s_exec+=" --selinux"
  fi
  local env_args=(
    INSTALL_K3S_EXEC="$k3s_exec"
    INSTALL_K3S_VERSION="${K3S_VERSION}"
  )
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
    if run_as_root "$K3S_BIN" kubectl get --raw=/readyz >/dev/null 2>&1; then
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

  # On enforcing RPM-family SELinux policies, the plugin's container_t domain
  # cannot connect to the k3s kubelet's container_runtime_t registration
  # socket. Scope the required host-level access to this infrastructure
  # DaemonSet; inference workers remain unprivileged.
  if [[ "$PACKAGE_FAMILY" == "rpm" ]] && have getenforce && [[ "$(getenforce)" == "Enforcing" ]]; then
    log "allowing the NVIDIA device plugin to register with k3s under enforcing SELinux"
    kubectl_cmd -n kube-system patch daemonset nvidia-device-plugin-daemonset \
      --type=json \
      -p '[{"op":"replace","path":"/spec/template/spec/containers/0/securityContext","value":{"privileged":true}}]' \
      >/dev/null
  fi

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
ensure_model_storage
configure_rpm_model_selinux
ensure_nvidia_drivers
ensure_nvidia_container_toolkit
configure_rpm_firewalld
configure_k3s_cgroup_compat
ensure_k3s
wait_k3s_api
ensure_kubectl
configure_k3s_nvidia_runtime
apply_nvidia_device_plugin
wait_nvidia_gpu_allocatable
ensure_deployment_namespace

cat <<EOF

Install finished.
EOF
