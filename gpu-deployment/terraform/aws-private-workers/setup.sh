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
  2. asks for the model and worker domain;
  3. generates terraform.tfvars with discover-aws.sh;
  4. initializes and validates Terraform;
  5. adopts matching existing worker resources and runs the plan;
  6. optionally runs terraform apply.

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

# Terraform's AWS provider does not always pick up `aws login` / SSO
# sessions from the CLI cache. Export resolved credentials into the
# environment so init/plan/apply use the same identity as the wizard.
export_aws_credentials_for_terraform() {
  local creds
  if ! creds="$(
    aws "${AWS_GLOBAL_ARGS[@]}" configure export-credentials --format env
  )"; then
    echo "error: failed to export AWS credentials for Terraform. Run 'aws login' and retry." >&2
    exit 1
  fi
  # Credentials are emitted as export FOO=... lines by the AWS CLI.
  eval "$creds"
  export AWS_REGION="$REGION"
  export AWS_DEFAULT_REGION="$REGION"
  if [[ -n "$PROFILE" ]]; then
    export AWS_PROFILE="$PROFILE"
  fi
  # Avoid a long IMDS timeout on laptops when credentials are already set.
  export AWS_EC2_METADATA_DISABLED=true
}

terraform_config_value() {
  local expression="$1"
  local console_output
  local line
  local value

  if ! console_output="$(
    printf '%s\n' "$expression" | terraform console 2>/dev/null
  )"; then
    printf 'error: unable to evaluate Terraform expression: %s\n' \
      "$expression" >&2
    exit 1
  fi

  value=""
  while IFS= read -r line; do
    [[ -n "$line" ]] && value="$line"
  done <<<"$console_output"
  if [[ -z "$value" ]]; then
    printf 'error: Terraform expression returned no value: %s\n' \
      "$expression" >&2
    exit 1
  fi

  # The expressions used here return simple strings or numbers. Terraform
  # console quotes strings, so remove only their outer quotes.
  if [[ "$value" == \"*\" ]]; then
    value="${value#\"}"
    value="${value%\"}"
  fi
  printf '%s\n' "$value"
}

terraform_state_has() {
  terraform state show "$1" >/dev/null 2>&1
}

terraform_adopt() {
  local address="$1"
  local import_id="$2"
  local description="$3"

  if terraform_state_has "$address"; then
    return
  fi

  printf 'Adopting existing %s into %s\n' "$description" "$address"
  terraform import -input=false "$address" "$import_id"
}

resource_conflict() {
  printf 'error: existing %s conflicts with the selected configuration: %s\n' \
    "$1" "$2" >&2
  exit 1
}

auto_adopt_existing_worker_resources() {
  local worker_names=()
  local worker_names_text
  local worker_name
  local worker_vpc_id
  local worker_domain
  local route53_zone
  local route53_zone_id
  local node_port
  local target_group_name
  local target_group_row
  local target_group_arn
  local target_group_vpc_id
  local target_group_protocol
  local target_group_port
  local target_group_address
  local nlb_name
  local nlb_row
  local nlb_arn
  local nlb_vpc_id
  local nlb_scheme
  local nlb_type
  local nlb_dns_name
  local nlb_address
  local listener_row
  local listener_arn
  local listener_protocol
  local listener_address
  local record_name
  local record_row
  local record_type
  local record_alias
  local expected_alias
  local actual_alias
  local record_address

  worker_names_text="$(
    terraform_config_value 'join(" ", keys(var.workers))'
  )"
  read -r -a worker_names <<<"$worker_names_text"
  worker_vpc_id="$(terraform_config_value 'var.worker_vpc_id')"
  worker_domain="$(terraform_config_value 'var.worker_domain')"
  route53_zone="$(terraform_config_value 'var.route53_zone_name')"
  route53_zone_id="$(
    aws_read route53 list-hosted-zones-by-name \
      --dns-name "$route53_zone" \
      --query "HostedZones[?Name=='${route53_zone}.' && Config.PrivateZone==\`false\`]|[0].Id" \
      --output text
  )"
  if [[ -z "$route53_zone_id" || "$route53_zone_id" == "None" ]]; then
    resource_conflict "Route 53 configuration" \
      "public zone $route53_zone was not found"
  fi
  route53_zone_id="${route53_zone_id##*/}"

  echo
  echo "Checking for existing worker resources to adopt..."

  for worker_name in "${worker_names[@]}"; do
    node_port="$(
      terraform_config_value "var.workers[\"${worker_name}\"].node_port"
    )"
    target_group_name="$(
      terraform_config_value \
        "local.worker_target_group_names[\"${worker_name}\"]"
    )"
    target_group_address="aws_lb_target_group.worker[\"${worker_name}\"]"
    target_group_row="$(
      aws_read elbv2 describe-target-groups \
        --query "TargetGroups[?TargetGroupName=='${target_group_name}'].[TargetGroupArn,VpcId,Protocol,Port]" \
        --output text
    )"

    if [[ -n "$target_group_row" && "$target_group_row" != "None" ]]; then
      IFS=$'\t' read -r \
        target_group_arn \
        target_group_vpc_id \
        target_group_protocol \
        target_group_port <<<"$target_group_row"

      if [[ "$target_group_vpc_id" != "$worker_vpc_id" ]]; then
        resource_conflict "target group $target_group_name" \
          "VPC is $target_group_vpc_id, expected $worker_vpc_id"
      fi
      if [[ "$target_group_protocol" != "TCP" ||
        "$target_group_port" != "$node_port" ]]; then
        resource_conflict "target group $target_group_name" \
          "protocol/port is $target_group_protocol/$target_group_port, expected TCP/$node_port"
      fi
      terraform_adopt \
        "$target_group_address" \
        "$target_group_arn" \
        "target group $target_group_name"
    fi

    nlb_name="$(
      terraform_config_value "local.worker_nlb_names[\"${worker_name}\"]"
    )"
    nlb_address="aws_lb.worker[\"${worker_name}\"]"
    nlb_row="$(
      aws_read elbv2 describe-load-balancers \
        --query "LoadBalancers[?LoadBalancerName=='${nlb_name}'].[LoadBalancerArn,VpcId,Scheme,Type,DNSName]" \
        --output text
    )"
    nlb_arn=""
    nlb_dns_name=""

    if [[ -n "$nlb_row" && "$nlb_row" != "None" ]]; then
      IFS=$'\t' read -r \
        nlb_arn \
        nlb_vpc_id \
        nlb_scheme \
        nlb_type \
        nlb_dns_name <<<"$nlb_row"

      if [[ "$nlb_vpc_id" != "$worker_vpc_id" ]]; then
        resource_conflict "load balancer $nlb_name" \
          "VPC is $nlb_vpc_id, expected $worker_vpc_id"
      fi
      if [[ "$nlb_scheme" != "internal" || "$nlb_type" != "network" ]]; then
        resource_conflict "load balancer $nlb_name" \
          "scheme/type is $nlb_scheme/$nlb_type, expected internal/network"
      fi
      terraform_adopt "$nlb_address" "$nlb_arn" "NLB $nlb_name"

      listener_address="aws_lb_listener.worker_tls[\"${worker_name}\"]"
      listener_row="$(
        aws_read elbv2 describe-listeners \
          --load-balancer-arn "$nlb_arn" \
          --query 'Listeners[?Port==`443`].[ListenerArn,Protocol]' \
          --output text
      )"
      if [[ -n "$listener_row" && "$listener_row" != "None" ]]; then
        IFS=$'\t' read -r listener_arn listener_protocol <<<"$listener_row"
        if [[ "$listener_protocol" != "TLS" ]]; then
          resource_conflict "listener on $nlb_name:443" \
            "protocol is $listener_protocol, expected TLS"
        fi
        terraform_adopt \
          "$listener_address" \
          "$listener_arn" \
          "TLS listener for $nlb_name"
      fi
    fi

    record_name="${worker_name}.${worker_domain}"
    record_address="aws_route53_record.worker[\"${worker_name}\"]"
    # A tracked record belongs to this configuration. If its NLB was deleted
    # out of band, Terraform will recreate the missing NLB and update the
    # existing alias during the plan/apply cycle.
    if terraform_state_has "$record_address"; then
      continue
    fi
    record_row="$(
      aws_read route53 list-resource-record-sets \
        --hosted-zone-id "$route53_zone_id" \
        --query "ResourceRecordSets[?Name=='${record_name}.' && Type=='A'].[Type,AliasTarget.DNSName]" \
        --output text
    )"
    if [[ -n "$record_row" && "$record_row" != "None" ]]; then
      IFS=$'\t' read -r record_type record_alias <<<"$record_row"
      if [[ -z "$nlb_dns_name" ]]; then
        resource_conflict "DNS record $record_name" \
          "matching NLB $nlb_name was not found"
      fi
      if [[ -z "$record_alias" || "$record_alias" == "None" ]]; then
        resource_conflict "DNS record $record_name" \
          "record is not an alias to $nlb_name"
      fi
      expected_alias="$(
        printf '%s' "${nlb_dns_name%.}" | tr '[:upper:]' '[:lower:]'
      )"
      actual_alias="$(
        printf '%s' "${record_alias%.}" | tr '[:upper:]' '[:lower:]'
      )"
      if [[ "$actual_alias" != "$expected_alias" ]]; then
        resource_conflict "DNS record $record_name" \
          "alias is $record_alias, expected $nlb_dns_name"
      fi
      terraform_adopt \
        "$record_address" \
        "${route53_zone_id}_${record_name}_${record_type}" \
        "DNS record $record_name"
    fi
  done
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
export_aws_credentials_for_terraform
terraform fmt terraform.tfvars
terraform init
terraform validate
auto_adopt_existing_worker_resources
terraform plan

if [[ "$PLAN_ONLY" == "true" ]]; then
  echo
  echo "Plan complete. Run apply when ready:"
  printf '  cd %s\n' "$SCRIPT_DIR"
  echo '  eval "$(aws configure export-credentials --format env)"'
  echo '  terraform apply'
  exit 0
fi

echo
read -r -p "Run terraform apply now? [y/N]: " apply_now
if [[ "$apply_now" =~ ^[Yy]$ ]]; then
  export_aws_credentials_for_terraform
  terraform apply
  echo
  echo "Worker endpoints:"
  terraform output worker_endpoints
  echo
  echo "Gateway allowlist suffix:"
  terraform output gateway_route_allowed_host_suffix
else
  echo "Plan complete. Run apply when ready:"
  printf '  cd %s\n' "$SCRIPT_DIR"
  echo '  eval "$(aws configure export-credentials --format env)"'
  echo '  terraform apply'
fi
