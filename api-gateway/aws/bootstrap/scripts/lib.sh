#!/usr/bin/env bash
# Shared helpers for bootstrap / ensure-host / run-agent (SSM + terraform outputs).
# shellcheck shell=bash

bootstrap_need() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "ERROR: $1 is required" >&2
    exit 1
  }
}

bootstrap_resolve_targets() {
  INSTANCE_ID="${INSTANCE_ID:-}"
  REGION="${AWS_REGION:-}"
  if [[ -z "${INSTANCE_ID}" ]]; then
    INSTANCE_ID="$(terraform output -raw instance_id 2>/dev/null || true)"
  fi
  if [[ -z "${REGION}" ]]; then
    REGION="$(terraform output -raw aws_region 2>/dev/null || true)"
  fi
  [[ -n "${INSTANCE_ID}" ]] || {
    echo "ERROR: could not resolve instance_id (run ./scripts/bootstrap.sh first, or set INSTANCE_ID)" >&2
    exit 1
  }
  [[ -n "${REGION}" ]] || {
    echo "ERROR: could not resolve aws_region (set AWS_REGION or re-run bootstrap)" >&2
    exit 1
  }
}

bootstrap_wait_ssm() {
  local ping_status=""
  local ready=0
  echo "[ensure-host] waiting for SSM managed instance ${INSTANCE_ID} (${REGION})…"
  for _ in $(seq 1 60); do
    ping_status="$(aws ssm describe-instance-information \
      --region "${REGION}" \
      --filters "Key=InstanceIds,Values=${INSTANCE_ID}" \
      --query 'InstanceInformationList[0].PingStatus' \
      --output text 2>/dev/null || echo "None")"
    if [[ "${ping_status}" == "Online" ]]; then
      ready=1
      break
    fi
    sleep 5
  done
  if [[ "${ready}" -ne 1 ]]; then
    echo "ERROR: instance ${INSTANCE_ID} is not SSM Online (status=${ping_status:-unknown})." >&2
    echo "Check amazon-ssm-agent / instance profile / network egress." >&2
    exit 1
  fi
}

# Run a shell script on the instance via SSM (script body as arg 1).
bootstrap_ssm_run() {
  local script="$1"
  local timeout="${2:-900}"
  local label="${3:-ssm}"
  local cmd_id status

  cmd_id="$(aws ssm send-command \
    --region "${REGION}" \
    --instance-ids "${INSTANCE_ID}" \
    --document-name "AWS-RunShellScript" \
    --timeout-seconds "${timeout}" \
    --parameters "$(jq -n --arg c "${script}" '{commands:[$c]}')" \
    --query 'Command.CommandId' \
    --output text)"

  echo "[${label}] command_id=${cmd_id}"
  aws ssm wait command-executed \
    --region "${REGION}" \
    --command-id "${cmd_id}" \
    --instance-id "${INSTANCE_ID}" 2>/dev/null || true

  status="$(aws ssm get-command-invocation \
    --region "${REGION}" \
    --command-id "${cmd_id}" \
    --instance-id "${INSTANCE_ID}" \
    --query 'Status' \
    --output text)"

  aws ssm get-command-invocation \
    --region "${REGION}" \
    --command-id "${cmd_id}" \
    --instance-id "${INSTANCE_ID}" \
    --query '{Status:Status,Stdout:StandardOutputContent,Stderr:StandardErrorContent}' \
    --output json

  if [[ "${status}" != "Success" ]]; then
    echo "ERROR: SSM command status=${status}" >&2
    exit 1
  fi
}

# Push scripts/host-setup.sh and run it (idempotent). Updates on-disk script each time.
bootstrap_ensure_host() {
  local setup_path="$1"
  local b64 remote

  [[ -f "${setup_path}" ]] || {
    echo "ERROR: host setup script missing: ${setup_path}" >&2
    exit 1
  }

  bootstrap_resolve_targets
  bootstrap_wait_ssm

  echo "[ensure-host] applying idempotent host-setup on ${INSTANCE_ID}…"
  b64="$(base64 <"${setup_path}" | tr -d '\n')"
  remote="set -euo pipefail
printf '%s' '${b64}' | base64 -d >/usr/local/sbin/api-gateway-infra-host-setup.sh
chmod +x /usr/local/sbin/api-gateway-infra-host-setup.sh
/usr/local/sbin/api-gateway-infra-host-setup.sh
"
  bootstrap_ssm_run "${remote}" 900 "ensure-host"
  echo "[ensure-host] host ready (Docker + compose + kubectl)"
}
