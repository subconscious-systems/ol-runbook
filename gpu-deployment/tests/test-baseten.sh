#!/usr/bin/env bash
# Test config selection and push delegation without invoking Truss or a cloud API.
set -euo pipefail
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
bash -n "${TEST_DIR}/../baseten/deploy.sh"
PYTHONDONTWRITEBYTECODE=1 python3 "${TEST_DIR}/test_baseten.py"
