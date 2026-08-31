#!/usr/bin/env bash
set -euo pipefail

GPU_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROFILE_DIR="${GPU_DIR}/profiles"

bash -n "${GPU_DIR}/dependencies.sh"
bash -n "${PROFILE_DIR}/install.sh"
bash -n "${PROFILE_DIR}/weights.sh"

for profile in "${PROFILE_DIR}"/*.yaml; do
  name="$(basename "${profile}")"
  grep -Fq "./weights.sh ${name}" "${profile}"
  if grep -A1 '^  modelDownload:$' "${profile}" | grep -q 'enabled: true'; then
    echo "ERROR: Kubernetes model download is enabled in ${name}" >&2
    exit 1
  fi
  grep -q 'hfRepo:' "${profile}"
  grep -q 'targetPath:' "${profile}"
  grep -q 'readOnly: true' "${profile}"
done

echo "OK: GPU profile scripts and host-download metadata"
