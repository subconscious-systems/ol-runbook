#!/usr/bin/env bash
# Autodiscover and run every */tests/test-*.sh under this repo (no cloud required).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT}"

TEST_SCRIPTS=()
while IFS= read -r line; do
  TEST_SCRIPTS+=("${line}")
done < <(find "${ROOT}" -type f -path '*/tests/test-*.sh' | sort)

if [[ "${#TEST_SCRIPTS[@]}" -eq 0 ]]; then
  echo "ERROR: no */tests/test-*.sh suites found under ${ROOT}" >&2
  exit 1
fi

echo "== ol-runbook tests (${#TEST_SCRIPTS[@]} suite(s)) =="
for t in "${TEST_SCRIPTS[@]}"; do
  rel="${t#"${ROOT}"/}"
  echo "-- ${rel} --"
  bash "${t}"
done

echo "OK: ${#TEST_SCRIPTS[@]} suite(s) passed"
