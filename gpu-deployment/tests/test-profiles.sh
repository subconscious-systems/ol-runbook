#!/usr/bin/env bash
set -euo pipefail

GPU_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROFILE_DIR="${GPU_DIR}/profiles"

bash -n "${GPU_DIR}/dependencies.sh"
bash -n "${PROFILE_DIR}/install.sh"
bash -n "${PROFILE_DIR}/_weights.sh"

grep -Fq 'rocky | rhel | centos | almalinux)' "${PROFILE_DIR}/install.sh"
grep -Fq 'stable/rpm/nvidia-container-toolkit.repo' "${PROFILE_DIR}/install.sh"
grep -Fq 'k3s_exec+=" --selinux"' "${PROFILE_DIR}/install.sh"
grep -Fq 'firewall-cmd --permanent --zone=trusted' "${PROFILE_DIR}/install.sh"
grep -Fq 'K3S_FIREWALL_NODEPORTS must stay within' "${PROFILE_DIR}/install.sh"
grep -Fq 'semanage fcontext -a -t container_file_t' "${PROFILE_DIR}/install.sh"
grep -Fq 'restorecon -RF' "${PROFILE_DIR}/install.sh"
grep -Fq 'stat -fc %T /sys/fs/cgroup' "${PROFILE_DIR}/install.sh"
grep -Fq 'fail-cgroupv1=false' "${PROFILE_DIR}/install.sh"

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
  ! grep -Eq 'hostModelDownloads|hfRepo|targetPath|modelDownload' "${profile}"
  grep -q 'readOnly: true' "${profile}"
done

echo "OK: GPU profile scripts and host-download metadata"
