#!/usr/bin/env bash
# Print Hub DASHBOARD_ALLOWED_IPS for this computer's current public IPv4.
#
# Helm owns Ingress spec.rules and the dashboard source-IP annotation. Do not
# kubectl-annotate the live Ingress: the next infra fragment PUT conflicts or
# reverts the list. Persist the printed field and re-run the infra Application.
set -euo pipefail

need() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "ERROR: $1 is required" >&2
    exit 1
  }
}

usage() {
  cat >&2 <<'EOF'
usage:
  ./scripts/add-dashboard-ip.sh [--existing <ip[,ip...]>]

Example:
  ./scripts/add-dashboard-ip.sh
  ./scripts/add-dashboard-ip.sh --existing 198.51.100.10,203.0.113.20

Detects this computer's public IPv4 and prints DASHBOARD_ALLOWED_IPS for the
private Distr infra environment. Merge with any IPs already in that Hub field
(maximum three). Then save the field and re-run the infra Application so Helm
applies the list.
EOF
}

EXISTING_RAW=""
if [[ $# -eq 0 ]]; then
  :
elif [[ $# -eq 1 && "$1" == "-h" || $# -eq 1 && "$1" == "--help" ]]; then
  usage
  exit 0
elif [[ $# -eq 2 && "$1" == "--existing" ]]; then
  EXISTING_RAW="$2"
elif [[ $# -eq 2 && "$1" != --* ]]; then
  echo "ERROR: this script no longer takes deployment names or patches Kubernetes." >&2
  echo "Set DASHBOARD_ALLOWED_IPS in Hub and re-run the infra Application." >&2
  usage
  exit 2
else
  usage
  exit 2
fi

need curl
need python3

PUBLIC_IP="$(
  curl --fail --silent --show-error --max-time 15 \
    https://checkip.amazonaws.com \
    | tr -d '[:space:]'
)"

DASHBOARD_ALLOWED_IPS="$(
  python3 - "${PUBLIC_IP}" "${EXISTING_RAW}" <<'PY'
import ipaddress
import sys

current = ipaddress.ip_address(sys.argv[1])
if current.version != 4:
    raise SystemExit("current public address is not IPv4")

values = []
seen = set()
raw_existing = sys.argv[2].strip()
parts = [part.strip() for part in raw_existing.split(",") if part.strip()] if raw_existing else []
for part in [*parts, str(current)]:
    text = part[:-3] if part.endswith("/32") else part
    address = ipaddress.ip_address(text)
    if address.version != 4:
        raise SystemExit(f"DASHBOARD_ALLOWED_IPS entries must be IPv4: {part}")
    if address.compressed in seen:
        continue
    seen.add(address.compressed)
    values.append(address.compressed)

if len(values) > 3:
    raise SystemExit("DASHBOARD_ALLOWED_IPS supports at most three IPv4 addresses")

print(",".join(values))
PY
)"

echo "[dashboard-ip] current public IPv4: ${PUBLIC_IP}/32"
echo "[dashboard-ip] Persist in the private Distr infra environment, then re-run infra:"
echo "DASHBOARD_ALLOWED_IPS=${DASHBOARD_ALLOWED_IPS}"
echo "[dashboard-ip] Helm applies the list on the next fragment PUT. Do not kubectl annotate Ingress."
