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
grep -Fq 'run_as_root apt-get install -y python3 python3-venv' "${PROFILE_DIR}/_weights.sh"
grep -Fq 'run_as_root dnf install -y python3.11 python3.11-pip' "${PROFILE_DIR}/_weights.sh"
# shellcheck disable=SC2016
grep -Fq 'python_is_supported "$HF_CLI_VENV/bin/python"' "${PROFILE_DIR}/_weights.sh"
# shellcheck disable=SC2016
grep -Fq 'python_has_venv "$HF_CLI_VENV/bin/python"' "${PROFILE_DIR}/_weights.sh"
# shellcheck disable=SC2016
grep -Fq 'hf_cli_works "$HF_CLI_VENV/bin/hf"' "${PROFILE_DIR}/_weights.sh"
test "$(grep -nE 'ensure_hf_cli|Hugging Face token:' "${PROFILE_DIR}/_weights.sh" | tail -2 | cut -d: -f2-)" = $'ensure_hf_cli\nread -r -s -p "Hugging Face token: " HF_TOKEN_INPUT'

nvfp4_values="${PROFILE_DIR}/glm-5.2-nvfp4-b200-4gpu/values.yaml"
grep -Fq '      path: /mnt' "$nvfp4_values"
grep -Fq '      mountPath: /mnt' "$nvfp4_values"
grep -Fq '  modelPath: /mnt/model-test/glm-5.2-nvfp4' "$nvfp4_values"
if grep -Fq 'runtimePreset:' "$nvfp4_values"; then
  echo "ERROR: NVFP4 profile must expose its runtime settings directly" >&2
  exit 1
fi
grep -Fq '    memFractionStatic: "0.82"' "$nvfp4_values"
grep -Fq '    maxRunningRequests: "96"' "$nvfp4_values"
grep -Fq -- '--enable-hierarchical-cache' "$nvfp4_values"
grep -Fq -- '--hicache-ratio 2' "$nvfp4_values"
grep -Fq -- '--subconscious-x-st-buffer-size 5' "$nvfp4_values"
grep -Fq -- '--subconscious-x-min-span-length 3' "$nvfp4_values"
grep -Fq -- '--speculative-algorithm DFLASH' "$nvfp4_values"
grep -Fq -- '--speculative-draft-model-path /mnt/model-test/glm-5.2-fp8-dflash-v2' "$nvfp4_values"
grep -Fq -- '--speculative-num-draft-tokens 12' "$nvfp4_values"
grep -Fq -- '--speculative-draft-kv-cache-dtype bfloat16' "$nvfp4_values"
grep -Fq -- '--speculative-draft-attention-backend fa4' "$nvfp4_values"
grep -Fq -- '--cuda-graph-max-bs 96' "$nvfp4_values"
grep -Fq '  extraEnv:' "$nvfp4_values"
grep -Fq '    - name: CUDA_VISIBLE_DEVICES' "$nvfp4_values"
grep -Fq '    - name: SGLANG_SUBCONSCIOUS_TRANSPLANT' "$nvfp4_values"
nvfp4_weights="${PROFILE_DIR}/glm-5.2-nvfp4-b200-4gpu/weights.sh"
grep -Fq 'nvidia/GLM-5.2-NVFP4" "/mnt/model-test/glm-5.2-nvfp4' "$nvfp4_weights"
grep -Fq 'SubconsciousDev/glm-5.2-fp8-dflash-v2" "/mnt/model-test/glm-5.2-fp8-dflash-v2' "$nvfp4_weights"

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
