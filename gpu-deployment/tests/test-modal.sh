#!/usr/bin/env bash
# Verify native Modal profiles without the SDK, credentials, or cloud calls.
set -euo pipefail
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHONDONTWRITEBYTECODE=1 python3 "${TEST_DIR}/test_modal.py"
