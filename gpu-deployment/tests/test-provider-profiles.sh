#!/usr/bin/env bash
# Requires PyYAML (CI installs the pinned version); no cloud calls.
set -euo pipefail
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHONDONTWRITEBYTECODE=1 python3 "${TEST_DIR}/test_provider_profiles.py"
