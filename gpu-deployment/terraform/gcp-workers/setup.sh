#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
TFVARS_FILE="$SCRIPT_DIR/terraform.tfvars"
PLAN_FILE="$SCRIPT_DIR/tfplan"

PROJECT_ID=""
DNS_PROJECT_ID=""
REGION=""
EXPOSURE_MODE=""
PLAN_ONLY=false

usage() {
  cat <<'EOF'
Interactively configure and plan GCP worker HTTPS routing.

Usage:
  ./setup.sh [--project PROJECT_ID] [--dns-project PROJECT_ID]
             [--region REGION] [--mode internal|public-api-key] [--plan-only]

Modes:
  internal        Private regional HTTPS load balancer reached from a same-
                  region gateway GKE VPC over VPC Network Peering.
  public-api-key  Public regional HTTPS load balancer. The wizard requires an
                  explicit confirmation that SGLANG_WORKER_API_KEY is enabled.

The wizard discovers the GPU VM, VPC/subnet, gateway GKE network (internal
mode), proxy-only subnet, Cloud DNS zone, and reusable regional certificate.
It writes terraform.tfvars, initializes and validates Terraform, runs a saved
plan, and optionally applies it.
EOF
}

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

log() {
  printf '%s\n' "$*" >&2
}

prompt() {
  local variable_name="$1"
  local message="$2"
  local default_value="${3:-}"
  local answer

  if [[ -n "$default_value" ]]; then
    read -r -p "$message [$default_value]: " answer
    answer="${answer:-$default_value}"
  else
    read -r -p "$message: " answer
  fi
  [[ -n "$answer" ]] || die "$message is required"
  printf -v "$variable_name" '%s' "$answer"
}

confirm() {
  local message="$1"
  local default_answer="${2:-no}"
  local suffix="[y/N]"
  local answer

  [[ "$default_answer" == "yes" ]] && suffix="[Y/n]"
  read -r -p "$message $suffix " answer
  answer="${answer:-$default_answer}"
  [[ "$answer" == "y" || "$answer" == "Y" || "$answer" == "yes" || "$answer" == "YES" ]]
}

# Input rows are tab-separated. The full selected row is printed to stdout;
# menus go to stderr so callers can safely use command substitution.
choose_row() {
  local message="$1"
  local rows="$2"
  local options=()
  local row
  local choice
  local index

  while IFS= read -r row; do
    [[ -n "$row" ]] && options+=("$row")
  done <<<"$rows"

  ((${#options[@]} > 0)) || die "no choices found for $message"
  if ((${#options[@]} == 1)); then
    log "$message: ${options[0]//$'\t'/ | }"
    printf '%s\n' "${options[0]}"
    return
  fi

  log "$message"
  for index in "${!options[@]}"; do
    printf '  %d) %s\n' "$((index + 1))" "${options[$index]//$'\t'/ | }" >&2
  done
  while true; do
    read -r -p "Select [1-${#options[@]}]: " choice
    if [[ "$choice" =~ ^[0-9]+$ ]] && ((choice >= 1 && choice <= ${#options[@]})); then
      printf '%s\n' "${options[$((choice - 1))]}"
      return
    fi
    log "Enter a number from 1 to ${#options[@]}."
  done
}

json_string() {
  python3 -c 'import json, sys; print(json.dumps(sys.argv[1]))' "$1"
}

basename_url() {
  printf '%s\n' "${1##*/}"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --project)
      [[ $# -ge 2 ]] || die "--project requires a value"
      PROJECT_ID="$2"
      shift 2
      ;;
    --dns-project)
      [[ $# -ge 2 ]] || die "--dns-project requires a value"
      DNS_PROJECT_ID="$2"
      shift 2
      ;;
    --region)
      [[ $# -ge 2 ]] || die "--region requires a value"
      REGION="$2"
      shift 2
      ;;
    --mode)
      [[ $# -ge 2 ]] || die "--mode requires a value"
      EXPOSURE_MODE="$2"
      shift 2
      ;;
    --plan-only)
      PLAN_ONLY=true
      shift
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      die "unknown option: $1"
      ;;
  esac
done

for command_name in gcloud terraform python3; do
  command -v "$command_name" >/dev/null 2>&1 || die "$command_name is required"
done

gcloud auth print-access-token >/dev/null 2>&1 ||
  die "gcloud is not authenticated; run 'gcloud auth login' and retry"

# Use the same short-lived identity for gcloud discovery and Terraform without
# writing service-account keys or credentials into terraform.tfvars.
export GOOGLE_OAUTH_ACCESS_TOKEN
GOOGLE_OAUTH_ACCESS_TOKEN="$(gcloud auth print-access-token)"

if [[ -z "$PROJECT_ID" ]]; then
  PROJECT_ID="$(gcloud config get-value project 2>/dev/null || true)"
  prompt PROJECT_ID "GPU worker project ID" "$PROJECT_ID"
fi
gcloud projects describe "$PROJECT_ID" --format='value(projectId)' >/dev/null ||
  die "cannot access worker project $PROJECT_ID"

if [[ -z "$DNS_PROJECT_ID" ]]; then
  prompt DNS_PROJECT_ID "Cloud DNS project ID" "$PROJECT_ID"
fi
gcloud projects describe "$DNS_PROJECT_ID" --format='value(projectId)' >/dev/null ||
  die "cannot access DNS project $DNS_PROJECT_ID"

if [[ -z "$REGION" ]]; then
  REGION="$(gcloud config get-value compute/region 2>/dev/null || true)"
  prompt REGION "Worker/load-balancer region" "$REGION"
fi

if [[ -z "$EXPOSURE_MODE" ]]; then
  mode_row="$(choose_row "Worker exposure mode" $'internal\tprivate VPC-peered HTTPS\npublic-api-key\tpublic HTTPS with worker bearer auth')"
  IFS=$'\t' read -r EXPOSURE_MODE _ <<<"$mode_row"
fi
[[ "$EXPOSURE_MODE" == "internal" || "$EXPOSURE_MODE" == "public-api-key" ]] ||
  die "mode must be internal or public-api-key"

log "Discovering running Compute Engine instances in $PROJECT_ID/$REGION..."
instance_json="$(
  gcloud compute instances list \
    --project "$PROJECT_ID" \
    --filter="zone:(${REGION}-*) AND status=RUNNING" \
    --format=json
)"
instance_rows="$(
  python3 -c '
import json, sys
for vm in json.load(sys.stdin):
    zone = vm.get("zone", "").rsplit("/", 1)[-1]
    accelerators = vm.get("guestAccelerators") or []
    gpu = ",".join(a.get("acceleratorType", "").rsplit("/", 1)[-1] for a in accelerators) or "no-gpu-metadata"
    print("\t".join((vm["name"], zone, gpu, vm.get("machineType", "").rsplit("/", 1)[-1])))
' <<<"$instance_json"
)"
instance_row="$(choose_row "GPU worker VM (name | zone | accelerator | machine type)" "$instance_rows")"
IFS=$'\t' read -r WORKER_INSTANCE_NAME WORKER_ZONE _ _ <<<"$instance_row"

instance_detail="$(
  gcloud compute instances describe "$WORKER_INSTANCE_NAME" \
    --project "$PROJECT_ID" \
    --zone "$WORKER_ZONE" \
    --format=json
)"
network_row="$(
  python3 -c '
import json, sys
vm = json.load(sys.stdin)
nic = vm["networkInterfaces"][0]
accounts = vm.get("serviceAccounts") or []
if not accounts:
    raise SystemExit("selected GPU VM has no service account; attach a dedicated service account and retry")
print("\t".join((
    nic["network"].rsplit("/", 1)[-1],
    nic["subnetwork"].rsplit("/", 1)[-1],
    accounts[0]["email"],
)))
' <<<"$instance_detail"
)"
IFS=$'\t' read -r WORKER_NETWORK_NAME WORKER_SUBNETWORK_NAME WORKER_SERVICE_ACCOUNT_EMAIL <<<"$network_row"

GATEWAY_PROJECT_ID=""
GATEWAY_NETWORK_NAME=""
MANAGE_NETWORK_PEERING=false
if [[ "$EXPOSURE_MODE" == "internal" ]]; then
  prompt GATEWAY_PROJECT_ID "Gateway GKE project ID" "$PROJECT_ID"
  cluster_json="$(
    gcloud container clusters list \
      --project "$GATEWAY_PROJECT_ID" \
      --format=json
  )"
  cluster_rows="$(
    python3 -c '
import json, sys
region = sys.argv[1]
for cluster in json.load(sys.stdin):
    location = cluster.get("location", "")
    if location == region or location.startswith(region + "-"):
        network = cluster.get("network", "").rsplit("/", 1)[-1]
        print("\t".join((cluster["name"], location, network)))
' "$REGION" <<<"$cluster_json"
  )"
  cluster_row="$(choose_row "Same-region gateway GKE cluster (name | location | network)" "$cluster_rows")"
  IFS=$'\t' read -r _ _ GATEWAY_NETWORK_NAME <<<"$cluster_row"

  if [[ "$GATEWAY_PROJECT_ID" == "$PROJECT_ID" && "$GATEWAY_NETWORK_NAME" == "$WORKER_NETWORK_NAME" ]]; then
    log "Gateway and worker already use the same VPC; peering is not needed."
  else
    MANAGE_NETWORK_PEERING=true
    if confirm "Are these VPCs already connected by peering in both directions?" "no"; then
      MANAGE_NETWORK_PEERING=false
    fi
  fi
fi

log "Checking for an ACTIVE proxy-only subnet in $WORKER_NETWORK_NAME/$REGION..."
proxy_json="$(
  gcloud compute networks subnets list \
    --project "$PROJECT_ID" \
    --regions "$REGION" \
    --filter="network~'/${WORKER_NETWORK_NAME}$' AND purpose=REGIONAL_MANAGED_PROXY AND role=ACTIVE" \
    --format=json
)"
PROXY_ONLY_SUBNET_NAME="$(
  python3 -c '
import json, sys
subnets = json.load(sys.stdin)
print(subnets[0]["name"] if subnets else "")
' <<<"$proxy_json"
)"
PROXY_ONLY_SUBNET_CIDR="10.129.0.0/23"
if [[ -n "$PROXY_ONLY_SUBNET_NAME" ]]; then
  log "Reusing proxy-only subnet: $PROXY_ONLY_SUBNET_NAME"
else
  prompt PROXY_ONLY_SUBNET_CIDR "New proxy-only subnet CIDR (/23 recommended)" "$PROXY_ONLY_SUBNET_CIDR"
fi

zone_json="$(
  gcloud dns managed-zones list \
    --project "$DNS_PROJECT_ID" \
    --filter='visibility=public' \
    --format=json
)"
zone_rows="$(
  python3 -c '
import json, sys
for zone in json.load(sys.stdin):
    print("\t".join((zone["name"], zone["dnsName"])))
' <<<"$zone_json"
)"
zone_row="$(choose_row "Public Cloud DNS zone (resource name | DNS suffix)" "$zone_rows")"
IFS=$'\t' read -r DNS_MANAGED_ZONE_NAME DNS_SUFFIX <<<"$zone_row"
DNS_SUFFIX="${DNS_SUFFIX%.}"
prompt WORKER_DOMAIN "Worker domain" "workers.$DNS_SUFFIX"
WORKER_DOMAIN="$(printf '%s' "$WORKER_DOMAIN" | tr '[:upper:]' '[:lower:]')"
WORKER_DOMAIN="${WORKER_DOMAIN%.}"
[[ "$WORKER_DOMAIN" == "$DNS_SUFFIX" || "$WORKER_DOMAIN" == *".$DNS_SUFFIX" ]] ||
  die "$WORKER_DOMAIN is not inside $DNS_SUFFIX"

model_row="$(choose_row "Worker layout" $'8b\t8b-a..8b-d on NodePorts 30003..30006\n27b\t27b-a..27b-b on NodePorts 30001..30002')"
IFS=$'\t' read -r MODEL _ <<<"$model_row"

CONFIRM_WORKER_API_KEY=false
if [[ "$EXPOSURE_MODE" == "public-api-key" ]]; then
  log ""
  log "PUBLIC MODE SECURITY GATE"
  log "The published worker profile must have worker.auth.enabled=true and its"
  log "SGLANG_WORKER_API_KEY Distr secret populated before this endpoint is public."
  confirm "I confirmed bearer auth is enabled on every selected worker" "no" ||
    die "public-api-key mode was not confirmed"
  CONFIRM_WORKER_API_KEY=true
fi

NAME_PREFIX_DEFAULT="$(printf '%s-workers' "$WORKER_INSTANCE_NAME" | tr '[:upper:]_' '[:lower:]-' | sed -E 's/[^a-z0-9-]+/-/g; s/^-+//; s/-+$//' | cut -c1-25)"
prompt NAME_PREFIX "GCP resource prefix" "$NAME_PREFIX_DEFAULT"

EXISTING_CERTIFICATE_ID=""
certificate_json="$(
  gcloud certificate-manager certificates list \
    --project "$PROJECT_ID" \
    --location "$REGION" \
    --format=json 2>/dev/null || printf '[]'
)"
certificate_rows="$(
  python3 -c '
import json, sys
wildcard = "*." + sys.argv[1]
for cert in json.load(sys.stdin):
    domains = (cert.get("managed") or {}).get("domains") or []
    if wildcard in domains:
        print("\t".join((cert["name"].rsplit("/", 1)[-1], (cert.get("managed") or {}).get("state", "unknown"))))
' "$WORKER_DOMAIN" <<<"$certificate_json"
)"
if [[ -n "$certificate_rows" ]]; then
  cert_row="$(choose_row "Matching regional certificate (name | state)" "$certificate_rows")"
  IFS=$'\t' read -r cert_name cert_state <<<"$cert_row"
  if [[ "$cert_state" == "ACTIVE" ]] && confirm "Reuse certificate $cert_name?" "yes"; then
    EXISTING_CERTIFICATE_ID="$cert_name"
  fi
fi

tmp_tfvars="$(mktemp "$SCRIPT_DIR/.terraform.tfvars.XXXXXX")"
trap 'rm -f "$tmp_tfvars"' EXIT
{
  printf 'project_id     = %s\n' "$(json_string "$PROJECT_ID")"
  printf 'dns_project_id = %s\n' "$(json_string "$DNS_PROJECT_ID")"
  printf 'region         = %s\n\n' "$(json_string "$REGION")"
  printf 'worker_zone            = %s\n' "$(json_string "$WORKER_ZONE")"
  printf 'worker_instance_name   = %s\n' "$(json_string "$WORKER_INSTANCE_NAME")"
  printf 'worker_service_account_email = %s\n' "$(json_string "$WORKER_SERVICE_ACCOUNT_EMAIL")"
  printf 'worker_network_name    = %s\n' "$(json_string "$WORKER_NETWORK_NAME")"
  printf 'worker_subnetwork_name = %s\n\n' "$(json_string "$WORKER_SUBNETWORK_NAME")"
  printf 'exposure_mode         = %s\n' "$(json_string "$EXPOSURE_MODE")"
  printf 'confirm_worker_api_key = %s\n\n' "$CONFIRM_WORKER_API_KEY"
  if [[ "$EXPOSURE_MODE" == "internal" ]]; then
    printf 'gateway_project_id     = %s\n' "$(json_string "$GATEWAY_PROJECT_ID")"
    printf 'gateway_network_name   = %s\n' "$(json_string "$GATEWAY_NETWORK_NAME")"
    printf 'manage_network_peering = %s\n\n' "$MANAGE_NETWORK_PEERING"
  fi
  if [[ -n "$PROXY_ONLY_SUBNET_NAME" ]]; then
    printf 'proxy_only_subnet_name = %s\n' "$(json_string "$PROXY_ONLY_SUBNET_NAME")"
  else
    printf 'proxy_only_subnet_name = null\n'
    printf 'proxy_only_subnet_cidr = %s\n' "$(json_string "$PROXY_ONLY_SUBNET_CIDR")"
  fi
  printf '\ndns_managed_zone_name = %s\n' "$(json_string "$DNS_MANAGED_ZONE_NAME")"
  printf 'worker_domain         = %s\n' "$(json_string "$WORKER_DOMAIN")"
  if [[ -n "$EXISTING_CERTIFICATE_ID" ]]; then
    printf 'existing_certificate_id = %s\n' "$(json_string "$EXISTING_CERTIFICATE_ID")"
  else
    printf 'existing_certificate_id = null\n'
  fi
  printf 'name_prefix = %s\n\n' "$(json_string "$NAME_PREFIX")"
  printf 'workers = {\n'
  if [[ "$MODEL" == "8b" ]]; then
    printf '  "8b-a" = { node_port = 30003 }\n'
    printf '  "8b-b" = { node_port = 30004 }\n'
    printf '  "8b-c" = { node_port = 30005 }\n'
    printf '  "8b-d" = { node_port = 30006 }\n'
  else
    printf '  "27b-a" = { node_port = 30001 }\n'
    printf '  "27b-b" = { node_port = 30002 }\n'
  fi
  printf '}\n'
} >"$tmp_tfvars"
mv "$tmp_tfvars" "$TFVARS_FILE"
trap - EXIT

log ""
log "Generated $TFVARS_FILE"
log "Mode:       $EXPOSURE_MODE"
log "GPU VM:     $PROJECT_ID/$WORKER_ZONE/$WORKER_INSTANCE_NAME"
log "Worker VPC: $WORKER_NETWORK_NAME"
log "DNS:        $WORKER_DOMAIN ($DNS_PROJECT_ID/$DNS_MANAGED_ZONE_NAME)"
log ""

cd "$SCRIPT_DIR"
terraform fmt
terraform init
terraform validate
terraform plan -out="$PLAN_FILE"

if [[ "$PLAN_ONLY" == "true" ]]; then
  log "Plan saved to $PLAN_FILE. Review terraform.tfvars, then run:"
  log "  cd $SCRIPT_DIR && terraform apply tfplan"
  exit 0
fi

if confirm "Apply this saved Terraform plan now?" "no"; then
  terraform apply "$PLAN_FILE"
  terraform output worker_endpoints
  log "Add $(terraform output -raw gateway_route_allowed_host_suffix) to gateway.routeAllowedHostSuffixes."
else
  log "Plan saved. Apply later with: cd $SCRIPT_DIR && terraform apply tfplan"
fi
