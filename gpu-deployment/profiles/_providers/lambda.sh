# shellcheck shell=bash
# Lambda provider: GPU instances via the Lambda Cloud API.
# Environment:
#   LAMBDA_API_KEY        API key from the Lambda Cloud console (required)
#   LAMBDA_REGION         region name (default us-south-1)
#   LAMBDA_INSTANCE_TYPE  override the topology -> instance type map
#   LAMBDA_SSH_KEY_NAME   name under which ${SSH_KEY}.pub is registered
#                         (default: subconscious-<SSH_KEY basename>)
# Notes: images ship with NVIDIA drivers preinstalled. Only topologies Lambda
# sells are mapped; anything else requires LAMBDA_INSTANCE_TYPE.
LAMBDA_API_KEY="${LAMBDA_API_KEY:-}"
LAMBDA_REGION="${LAMBDA_REGION:-us-south-1}"
SSH_USER="${SSH_USER:-ubuntu}"
LAMBDA_API_BASE="${LAMBDA_API_BASE:-https://api.lambdalabs.com/v1}"

provider_help() {
  cat <<'EOF'
Lambda environment:
  LAMBDA_API_KEY, LAMBDA_REGION, LAMBDA_INSTANCE_TYPE, LAMBDA_SSH_KEY_NAME
The public key ${SSH_KEY}.pub is registered automatically when missing.
Instances are addressed by SSH on the returned public IP.
EOF
}

lambda_get() {
  curl -fsSL -H "Authorization: Bearer ${LAMBDA_API_KEY}" "$@"
}

lambda_post() {
  curl -fsSL -H "Authorization: Bearer ${LAMBDA_API_KEY}" \
    -H 'Content-Type: application/json' "$@"
}

lambda_field() {
  python3 -c 'import json, sys
d = json.load(sys.stdin)
for part in sys.argv[1].split("."):
    d = d[int(part)] if isinstance(d, list) else d[part]
print(d)' "$1"
}

resolve_instance_type() {
  local gpu="$1" count="$2"
  if [[ -n "${LAMBDA_INSTANCE_TYPE:-}" ]]; then
    INSTANCE_TYPE="$LAMBDA_INSTANCE_TYPE"
    return
  fi
  case "${gpu}-${count}" in
    a100-80gb-1) INSTANCE_TYPE="gpu_1x_a100_80gb" ;;
    a100-80gb-2) INSTANCE_TYPE="gpu_2x_a100_80gb" ;;
    a100-80gb-4) INSTANCE_TYPE="gpu_4x_a100_80gb" ;;
    a100-80gb-8) INSTANCE_TYPE="gpu_8x_a100_80gb" ;;
    h100-80gb-1) INSTANCE_TYPE="gpu_1x_h100_pcie_80gb" ;;
    h100-80gb-2) INSTANCE_TYPE="gpu_2x_h100_80gb" ;;
    h100-80gb-4) INSTANCE_TYPE="gpu_4x_h100_80gb" ;;
    h100-80gb-8) INSTANCE_TYPE="gpu_8x_h100_nvlink_80gb" ;;
    h200-1) INSTANCE_TYPE="gpu_1x_h200" ;;
    h200-2) INSTANCE_TYPE="gpu_2x_h200" ;;
    h200-4) INSTANCE_TYPE="gpu_4x_h200" ;;
    h200-8) INSTANCE_TYPE="gpu_8x_h200_sxm" ;;
    b200-4) INSTANCE_TYPE="gpu_4x_b200_sxm" ;;
    b200-8) INSTANCE_TYPE="gpu_8x_b200_sxm" ;;
    *)
      die "no default Lambda instance type for ${gpu} x ${count}; set LAMBDA_INSTANCE_TYPE"
      ;;
  esac
  log "instance type: ${INSTANCE_TYPE}"
}

provision() {
  have curl || die "curl is required"
  have python3 || die "python3 is required to parse Lambda API responses"
  [[ -n "$LAMBDA_API_KEY" ]] || die "set LAMBDA_API_KEY (Lambda Cloud console -> API Keys)"
  require_pub_key

  local key_name key_id instance_id elapsed status
  key_name="${LAMBDA_SSH_KEY_NAME:-subconscious-$(basename "$SSH_KEY")}"
  key_id="$(lambda_get "${LAMBDA_API_BASE}/ssh-keys" | python3 -c 'import json, sys
rows = json.load(sys.stdin)["data"]
match = next((r for r in rows if r.get("name") == sys.argv[1]), None)
print(match["id"] if match else "")' "$key_name")"
  if [[ -z "$key_id" ]]; then
    log "registering SSH key ${key_name}"
    key_id="$(lambda_post "${LAMBDA_API_BASE}/ssh-keys" \
      -d "{\"name\": \"${key_name}\", \"public_key\": $(python3 -c 'import json,sys; print(json.dumps(open(sys.argv[1]).read()))' "${SSH_KEY}.pub")}" |
      lambda_field 'data.id')"
    [[ -n "$key_id" ]] || die "could not register the SSH key with Lambda"
  fi

  log "launching ${INSTANCE_TYPE} in ${LAMBDA_REGION}"
  instance_id="$(lambda_post "${LAMBDA_API_BASE}/instances" \
    -d "{\"name\": \"${INSTANCE_NAME}\", \"region_name\": \"${LAMBDA_REGION}\", \"instance_type\": \"${INSTANCE_TYPE}\", \"quantity\": 1, \"ssh_key_ids\": [\"${key_id}\"]}" |
    lambda_field 'data.instance_ids.0')"
  [[ -n "$instance_id" ]] || die "could not launch the Lambda instance (check region and quota)"

  elapsed=0
  log "waiting for ${instance_id} to become active"
  while ((elapsed < SSH_WAIT_TIMEOUT_SECONDS)); do
    status="$(lambda_get "${LAMBDA_API_BASE}/instances/${instance_id}" |
      lambda_field 'data.status' || true)"
    if [[ "$status" == "active" ]]; then
      SSH_HOST="$(lambda_get "${LAMBDA_API_BASE}/instances/${instance_id}" |
        lambda_field 'data.ip')"
      [[ -n "$SSH_HOST" ]] || die "instance is active but has no IP"
      log "instance active at ${SSH_HOST}"
      return
    fi
    sleep 15
    elapsed=$((elapsed + 15))
  done
  die "timed out waiting for the Lambda instance (last status: ${status:-unknown})"
}
