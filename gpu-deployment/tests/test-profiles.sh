#!/usr/bin/env bash
set -euo pipefail

GPU_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROFILE_DIR="${GPU_DIR}/profiles"

bash -n "${GPU_DIR}/dependencies.sh"
bash -n "${PROFILE_DIR}/install.sh"
bash -n "${PROFILE_DIR}/_weights.sh"

grep -Fq 'rocky | rhel | centos | almalinux)' "${PROFILE_DIR}/install.sh"
grep -Fq 'stable/rpm/nvidia-container-toolkit.repo' "${PROFILE_DIR}/install.sh"
grep -Fq 'python3.11 python3.11-pip' "${PROFILE_DIR}/install.sh"
grep -Fq 'k3s_exec+=" --selinux"' "${PROFILE_DIR}/install.sh"
grep -Fq 'firewall-cmd --permanent --zone=trusted' "${PROFILE_DIR}/install.sh"
grep -Fq 'K3S_FIREWALL_NODEPORTS must stay within' "${PROFILE_DIR}/install.sh"
grep -Fq 'semanage fcontext -a -t container_file_t' "${PROFILE_DIR}/install.sh"
grep -Fq 'restorecon -RF' "${PROFILE_DIR}/install.sh"
grep -Fq 'stat -fc %T /sys/fs/cgroup' "${PROFILE_DIR}/install.sh"
grep -Fq 'fail-cgroupv1=false' "${PROFILE_DIR}/install.sh"
# These are literal shell source fragments, not expressions for this test.
# shellcheck disable=SC2016
grep -Fq 'K3S_VERSION="${K3S_VERSION:-v1.36.0+k3s1}"' "${PROFILE_DIR}/install.sh"
# shellcheck disable=SC2016
grep -Fq 'INSTALL_K3S_VERSION="${K3S_VERSION}"' "${PROFILE_DIR}/install.sh"
grep -Fq 'NVIDIA/k8s-device-plugin/v0.19.3/' "${PROFILE_DIR}/install.sh"
# shellcheck disable=SC2016
grep -Fq '[[ "$PACKAGE_FAMILY" == "rpm" ]] && have getenforce && [[ "$(getenforce)" == "Enforcing" ]]' "${PROFILE_DIR}/install.sh"
grep -Fq '"privileged":true' "${PROFILE_DIR}/install.sh"
# shellcheck disable=SC2016
grep -Fq 'run_as_root "$K3S_BIN" kubectl get --raw=/readyz' "${PROFILE_DIR}/install.sh"
grep -Fq 'python3.13 python3.12 python3.11 python3.10 python3.9 python3' "${PROFILE_DIR}/_weights.sh"
if grep -Fq 'python3 -m venv --clear' "${PROFILE_DIR}/_weights.sh"; then
  exit 1
fi
# shellcheck disable=SC2016
grep -Fq '"$HF_PYTHON" -m venv --clear' "${PROFILE_DIR}/_weights.sh"

nvfp4_values="${PROFILE_DIR}/glm-5.2-nvfp4-b200-4gpu/values.yaml"
test "$(grep -Fc 'path: /mnt/glm-5.2-nvfp4' "$nvfp4_values")" -eq 1
test "$(grep -Fc 'mountPath: /mnt/glm-5.2-nvfp4' "$nvfp4_values")" -eq 1

for profile in "${PROFILE_DIR}"/*/values.yaml; do
  profile_dir="$(dirname "${profile}")"
  profile_name="$(basename "${profile_dir}")"
  bash -n "${profile_dir}/weights.sh"
  grep -q "${profile_name} profile" "${profile_dir}/weights.sh"
  test "$(find "${profile_dir}" -maxdepth 1 -type f | wc -l)" -eq 2
  grep -Fq './weights.sh' "${profile}"
  if grep -Eq 'hostModelDownloads|hfRepo|targetPath|modelDownload' "${profile}"; then
    echo "ERROR: ${profile} contains in-cluster model-download configuration" >&2
    exit 1
  fi
  grep -q 'readOnly: true' "${profile}"
done

echo "OK: GPU profile scripts and host-download metadata"
