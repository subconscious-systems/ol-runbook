#!/usr/bin/env bash

# AWS CLI JMESPath literals use backticks inside intentionally single-quoted
# query strings.
# shellcheck disable=SC2016

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
DISCOVER_SCRIPT="$SCRIPT_DIR/discover-aws.sh"
TFVARS_FILE="$SCRIPT_DIR/terraform.tfvars"

REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-}}"
PROFILE=""
PLAN_ONLY=false

usage() {
  cat <<'EOF'
Interactively configure and plan private AWS worker routing.

Usage:
  ./setup.sh [--region REGION] [--profile PROFILE] [--plan-only]

The wizard:
  1. lets you select the gateway EKS cluster, GPU instance, and Route 53 zone;
  2. asks for the model, worker domain, and gateway Helm identity;
  3. generates terraform.tfvars with discover-aws.sh;
  4. runs terraform init, validate, and plan;
  5. optionally runs terraform apply.

Options:
  --region REGION    AWS region. Defaults to AWS environment or CLI config.
  --profile PROFILE  AWS CLI named profile.
  --plan-only        Stop after terraform plan without offering to apply.
  -h, --help         Show this help.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --region)
      [[ $# -ge 2 ]] || {
        echo "error: --region requires a value" >&2
        exit 2
      }
      REGION="$2"
      shift 2
      ;;
    --profile)
      [[ $# -ge 2 ]] || {
        echo "error: --profile requires a value" >&2
        exit 2
      }
      PROFILE="$2"
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
      echo "error: unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

for command_name in aws terraform; do
  command -v "$command_name" >/dev/null 2>&1 || {
    printf 'error: %s is required\n' "$command_name" >&2
    exit 1
  }
done

[[ -x "$DISCOVER_SCRIPT" ]] || {
  printf 'error: discovery script is not executable: %s\n' \
    "$DISCOVER_SCRIPT" >&2
  exit 1
}

AWS_GLOBAL_ARGS=()
if [[ -n "$PROFILE" ]]; then
  AWS_GLOBAL_ARGS+=(--profile "$PROFILE")
fi

if [[ -z "$REGION" ]]; then
  REGION="$(aws "${AWS_GLOBAL_ARGS[@]}" configure get region 2>/dev/null || true)"
fi

if [[ -z "$REGION" ]]; then
  read -r -p "AWS region: " REGION
fi

[[ -n "$REGION" ]] || {
  echo "error: AWS region is required" >&2
  exit 1
}

AWS_GLOBAL_ARGS+=(--region "$REGION" --no-cli-pager)

aws_read() {
  aws "${AWS_GLOBAL_ARGS[@]}" "$@"
}

prompt_required() {
  local prompt="$1"
  local value=""

  while [[ -z "$value" ]]; do
    read -r -p "$prompt: " value
  done
  printf '%s\n' "$value"
}

choose_option() {
  local prompt="$1"
  shift
  local options=("$@")
  local selection=""
  local old_ps3="${PS3:-}"

  [[ ${#options[@]} -gt 0 ]] || {
    printf 'error: no choices available for %s\n' "$prompt" >&2
    return 1
  }

  PS3="$prompt [1-${#options[@]}]: "
  select selection in "${options[@]}"; do
    if [[ -n "$selection" ]]; then
      PS3="$old_ps3"
      printf '%s\n' "$REPLY"
      return 0
    fi
    echo "Choose a listed number." >&2
  done
}

echo "Checking AWS access..."
if ! identity="$(
  aws_read sts get-caller-identity \
    --query '[Account,Arn]' \
    --output text
)"; then
  echo "AWS authentication failed. Run 'aws login' and retry." >&2
  exit 1
fi
IFS=$'\t' read -r account_id caller_arn <<<"$identity"
printf 'Account: %s\nCaller:  %s\nRegion:  %s\n\n' \
  "$account_id" "$caller_arn" "$REGION"

cluster_text="$(
  aws_read eks list-clusters \
    --query 'clusters' \
    --output text
)"
read -r -a clusters <<<"$cluster_text"
echo "Select the EKS cluster containing the API gateway:"
cluster_choice="$(choose_option "EKS cluster" "${clusters[@]}")"
eks_cluster="${clusters[$((cluster_choice - 1))]}"

instance_rows="$(
  aws_read ec2 describe-instances \
    --filters Name=instance-state-name,Values=running \
    --query 'Reservations[].Instances[].[InstanceId,Tags[?Key==`Name`]|[0].Value,InstanceType,VpcId,Placement.AvailabilityZone]' \
    --output text
)"

instance_ids=()
instance_labels=()
while IFS=$'\t' read -r instance_id name instance_type vpc_id az; do
  [[ -n "$instance_id" ]] || continue
  [[ "$name" != "None" ]] || name="unnamed"
  instance_ids+=("$instance_id")
  instance_labels+=("$instance_id | $name | $instance_type | $vpc_id | $az")
done <<<"$instance_rows"

echo
echo "Select the running GPU EC2 instance:"
instance_choice="$(choose_option "GPU instance" "${instance_labels[@]}")"
gpu_instance_id="${instance_ids[$((instance_choice - 1))]}"

zone_text="$(
  aws_read route53 list-hosted-zones \
    --query 'HostedZones[?Config.PrivateZone==`false`].Name' \
    --output text
)"
read -r -a route53_zones <<<"$zone_text"
for index in "${!route53_zones[@]}"; do
  route53_zones[index]="${route53_zones[index]%.}"
done

echo
echo "Select the public Route 53 zone for worker DNS:"
zone_choice="$(choose_option "Route 53 zone" "${route53_zones[@]}")"
route53_zone="${route53_zones[$((zone_choice - 1))]}"

default_worker_domain="workers.$route53_zone"
read -r -p "Worker domain [$default_worker_domain]: " worker_domain
worker_domain="${worker_domain:-$default_worker_domain}"

echo
echo "Select the deployed worker profile:"
model_choice="$(choose_option "Model" "8b" "27b")"
if [[ "$model_choice" -eq 1 ]]; then
  model="8b"
else
  model="27b"
fi

echo
if command -v kubectl >/dev/null 2>&1; then
  echo "Gateway namespace and Helm release candidates from the current cluster:"
  kubectl get pods -A \
    --request-timeout=5s \
    -o custom-columns='NAMESPACE:.metadata.namespace,RELEASE:.metadata.labels.app\.kubernetes\.io/instance' \
    --no-headers 2>/dev/null \
    | sort -u \
    | grep -v '<none>' \
    || true
  echo
fi
gateway_namespace="$(prompt_required "Gateway namespace")"
gateway_release_name="$(prompt_required "Gateway Helm release name")"

security_group_text="$(
  aws_read ec2 describe-instances \
    --instance-ids "$gpu_instance_id" \
    --query 'Reservations[0].Instances[0].SecurityGroups[].GroupId' \
    --output text
)"
read -r -a security_group_ids <<<"$security_group_text"
worker_security_group_args=()

if [[ ${#security_group_ids[@]} -gt 1 ]]; then
  security_group_labels=()
  for security_group_id in "${security_group_ids[@]}"; do
    security_group_name="$(
      aws_read ec2 describe-security-groups \
        --group-ids "$security_group_id" \
        --query 'SecurityGroups[0].GroupName' \
        --output text
    )"
    security_group_labels+=("$security_group_id | $security_group_name")
  done

  echo
  echo "Select the GPU security group Terraform should use:"
  security_group_choice="$(
    choose_option "Security group" "${security_group_labels[@]}"
  )"
  worker_security_group_args=(
    --worker-security-group
    "${security_group_ids[$((security_group_choice - 1))]}"
  )
fi

echo
echo "Configuration:"
printf '  EKS cluster:       %s\n' "$eks_cluster"
printf '  GPU instance:      %s\n' "$gpu_instance_id"
printf '  Route 53 zone:     %s\n' "$route53_zone"
printf '  Worker domain:     %s\n' "$worker_domain"
printf '  Model:             %s\n' "$model"
printf '  Gateway namespace: %s\n' "$gateway_namespace"
printf '  Gateway release:   %s\n' "$gateway_release_name"

if [[ -e "$TFVARS_FILE" ]]; then
  read -r -p "terraform.tfvars already exists. Replace it? [y/N]: " replace
  if [[ ! "$replace" =~ ^[Yy]$ ]]; then
    echo "Stopped without changing terraform.tfvars."
    exit 0
  fi
fi

read -r -p "Generate terraform.tfvars with these values? [Y/n]: " confirm
if [[ "$confirm" =~ ^[Nn]$ ]]; then
  echo "Stopped without changing terraform.tfvars."
  exit 0
fi

discover_args=(
  --region "$REGION"
  --gpu-instance-id "$gpu_instance_id"
  --eks-cluster "$eks_cluster"
  --route53-zone "$route53_zone"
  --worker-domain "$worker_domain"
  --model "$model"
  --gateway-namespace "$gateway_namespace"
  --gateway-release-name "$gateway_release_name"
  --tfvars
)
if [[ -n "$PROFILE" ]]; then
  discover_args+=(--profile "$PROFILE")
fi
discover_args+=("${worker_security_group_args[@]}")

temporary_tfvars="$(mktemp "$SCRIPT_DIR/.terraform.tfvars.XXXXXX")"
cleanup() {
  rm -f "$temporary_tfvars"
}
trap cleanup EXIT

"$DISCOVER_SCRIPT" "${discover_args[@]}" >"$temporary_tfvars"
mv "$temporary_tfvars" "$TFVARS_FILE"
trap - EXIT

cd "$SCRIPT_DIR"
terraform fmt terraform.tfvars
terraform init
terraform validate
terraform plan

if [[ "$PLAN_ONLY" == "true" ]]; then
  echo
  echo "Plan complete. Run 'terraform apply' here when ready:"
  printf '  cd %s\n  terraform apply\n' "$SCRIPT_DIR"
  exit 0
fi

echo
read -r -p "Run terraform apply now? [y/N]: " apply_now
if [[ "$apply_now" =~ ^[Yy]$ ]]; then
  terraform apply
  echo
  echo "Worker endpoints:"
  terraform output worker_endpoints
  echo
  echo "Gateway allowlist suffix:"
  terraform output gateway_route_allowed_host_suffix
else
  echo "Plan complete. Run 'terraform apply' in this directory when ready."
fi
