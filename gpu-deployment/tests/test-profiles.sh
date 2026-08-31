#!/usr/bin/env bash
set -euo pipefail

GPU_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROFILE_DIR="${GPU_DIR}/profiles"

bash -n "${GPU_DIR}/dependencies.sh"
bash -n "${PROFILE_DIR}/install.sh"
bash -n "${PROFILE_DIR}/_weights.sh"

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
