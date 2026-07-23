#!/usr/bin/env bash

# AWS CLI JMESPath literals use backticks inside intentionally single-quoted
# query strings.
# shellcheck disable=SC2016

set -euo pipefail

REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-}}"
PROFILE=""
GPU_INSTANCE_ID=""
EKS_CLUSTER_NAME=""
ROUTE53_ZONE=""
WORKER_DOMAIN=""
MODEL=""
WORKER_SECURITY_GROUP_ID=""
TFVARS_MODE=false

usage() {
  cat <<'EOF'
Discover the AWS resources needed by the private-worker Terraform root.

This script is read-only. It does not create or modify AWS resources.

Usage:
  ./discover-aws.sh [options]

Options:
  --region REGION              AWS region. Defaults to AWS_REGION,
                               AWS_DEFAULT_REGION, or the AWS CLI config.
  --profile PROFILE            AWS CLI named profile.
  --gpu-instance-id ID         Resolve the worker VPC, subnet, AZ, and security
                               groups from this GPU EC2 instance.
  --eks-cluster NAME           Resolve the gateway VPC and private subnets from
                               this EKS cluster.
  --route53-zone DOMAIN        Show the exact public hosted zone, for example
                               example.com.
  --worker-domain DOMAIN       Show issued ACM certificates for the wildcard
                               worker domain, for example workers.example.com.
  --model MODEL                Worker profile for generated tfvars: 8b or 27b.
  --worker-security-group ID   Select an attached GPU security group when the
                               instance has more than one.
  --tfvars                     Print only complete terraform.tfvars HCL to
                               stdout. Requires all deployment choices above.
  -h, --help                   Show this help.

Examples:
  ./discover-aws.sh --region us-east-2

  ./discover-aws.sh \
    --region us-east-2 \
    --gpu-instance-id i-0123456789abcdef0 \
    --eks-cluster gateway-production \
    --route53-zone example.com \
    --worker-domain workers.example.com \
    --model 8b \
    --tfvars > terraform.tfvars
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
    --gpu-instance-id)
      [[ $# -ge 2 ]] || {
        echo "error: --gpu-instance-id requires a value" >&2
        exit 2
      }
      GPU_INSTANCE_ID="$2"
      shift 2
      ;;
    --eks-cluster)
      [[ $# -ge 2 ]] || {
        echo "error: --eks-cluster requires a value" >&2
        exit 2
      }
      EKS_CLUSTER_NAME="$2"
      shift 2
      ;;
    --route53-zone)
      [[ $# -ge 2 ]] || {
        echo "error: --route53-zone requires a value" >&2
        exit 2
      }
      ROUTE53_ZONE="${2%.}"
      shift 2
      ;;
    --worker-domain)
      [[ $# -ge 2 ]] || {
        echo "error: --worker-domain requires a value" >&2
        exit 2
      }
      WORKER_DOMAIN="${2%.}"
      shift 2
      ;;
    --model)
      [[ $# -ge 2 ]] || {
        echo "error: --model requires a value" >&2
        exit 2
      }
      MODEL="$2"
      shift 2
      ;;
    --worker-security-group)
      [[ $# -ge 2 ]] || {
        echo "error: --worker-security-group requires a value" >&2
        exit 2
      }
      WORKER_SECURITY_GROUP_ID="$2"
      shift 2
      ;;
    --tfvars)
      TFVARS_MODE=true
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

command -v aws >/dev/null 2>&1 || {
  echo "error: AWS CLI v2 is required" >&2
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
  echo "error: no AWS region configured; pass --region REGION" >&2
  exit 1
fi

AWS_GLOBAL_ARGS+=(--region "$REGION" --no-cli-pager)

aws_read() {
  aws "${AWS_GLOBAL_ARGS[@]}" "$@"
}

section() {
  printf '\n== %s ==\n' "$1"
}

tfvars_list() {
  local csv="$1"
  local indent="${2:-2}"
  local value
  local old_ifs="$IFS"

  IFS=','
  for value in $csv; do
    printf '%*s"%s",\n' "$indent" "" "$value"
  done
  IFS="$old_ifs"
}

generate_tfvars() {
  local missing=()
  local account_id
  local gateway_data
  local gateway_vpc_id
  local gateway_subnet_ids
  local worker_data
  local worker_vpc_id
  local worker_subnet_id
  local worker_az
  local worker_security_group_ids
  local worker_state
  local attached_security_groups=()
  local selected_security_group=""
  local security_group
  local found_security_group=false
  local route53_zone_private
  local peering_text
  local peering_ids=()
  local peering_id="null"
  local manage_vpc_routes="true"
  local certificate_text
  local certificate_arns=()
  local certificate_arn="null"

  [[ -n "$GPU_INSTANCE_ID" ]] || missing+=(--gpu-instance-id)
  [[ -n "$EKS_CLUSTER_NAME" ]] || missing+=(--eks-cluster)
  [[ -n "$ROUTE53_ZONE" ]] || missing+=(--route53-zone)
  [[ -n "$WORKER_DOMAIN" ]] || missing+=(--worker-domain)
  [[ -n "$MODEL" ]] || missing+=(--model)

  if [[ ${#missing[@]} -gt 0 ]]; then
    printf 'error: --tfvars also requires:' >&2
    printf ' %s' "${missing[@]}" >&2
    printf '\nRun with --help for the complete command.\n' >&2
    exit 2
  fi

  if [[ "$MODEL" != "8b" && "$MODEL" != "27b" ]]; then
    echo "error: --model must be 8b or 27b" >&2
    exit 2
  fi

  account_id="$(
    aws_read sts get-caller-identity \
      --query 'Account' \
      --output text
  )"

  gateway_data="$(
    aws_read eks describe-cluster \
      --name "$EKS_CLUSTER_NAME" \
      --query 'cluster.[resourcesVpcConfig.vpcId,join(`,`,resourcesVpcConfig.subnetIds)]' \
      --output text
  )"
  IFS=$'\t' read -r gateway_vpc_id gateway_subnet_ids <<<"$gateway_data"

  worker_data="$(
    aws_read ec2 describe-instances \
      --instance-ids "$GPU_INSTANCE_ID" \
      --query 'Reservations[0].Instances[0].[VpcId,SubnetId,Placement.AvailabilityZone,join(`,`,SecurityGroups[].GroupId),State.Name]' \
      --output text
  )"
  IFS=$'\t' read -r \
    worker_vpc_id \
    worker_subnet_id \
    worker_az \
    worker_security_group_ids \
    worker_state <<<"$worker_data"

  if [[ "$worker_state" != "running" ]]; then
    printf 'error: GPU instance %s is %s, not running\n' \
      "$GPU_INSTANCE_ID" "$worker_state" >&2
    exit 1
  fi

  IFS=',' read -r -a attached_security_groups \
    <<<"$worker_security_group_ids"

  if [[ -n "$WORKER_SECURITY_GROUP_ID" ]]; then
    for security_group in "${attached_security_groups[@]}"; do
      if [[ "$security_group" == "$WORKER_SECURITY_GROUP_ID" ]]; then
        found_security_group=true
        break
      fi
    done
    if [[ "$found_security_group" != "true" ]]; then
      printf 'error: %s is not attached to %s; attached groups: %s\n' \
        "$WORKER_SECURITY_GROUP_ID" \
        "$GPU_INSTANCE_ID" \
        "$worker_security_group_ids" >&2
      exit 2
    fi
    selected_security_group="$WORKER_SECURITY_GROUP_ID"
  elif [[ ${#attached_security_groups[@]} -eq 1 ]]; then
    selected_security_group="${attached_security_groups[0]}"
  else
    printf 'error: GPU instance has multiple security groups: %s\n' \
      "$worker_security_group_ids" >&2
    printf 'Rerun with --worker-security-group <one-attached-sg-id>.\n' >&2
    exit 2
  fi

  route53_zone_private="$(
    aws_read route53 list-hosted-zones-by-name \
      --dns-name "$ROUTE53_ZONE" \
      --query "HostedZones[?Name=='${ROUTE53_ZONE}.' && Config.PrivateZone==\`false\`]|[0].Config.PrivateZone" \
      --output text
  )"
  if [[ "$route53_zone_private" != "False" ]]; then
    printf 'error: %s is not an existing public Route 53 hosted zone\n' \
      "$ROUTE53_ZONE" >&2
    exit 2
  fi

  peering_text="$(
    aws_read ec2 describe-vpc-peering-connections \
      --query "VpcPeeringConnections[?Status.Code=='active' && ((RequesterVpcInfo.VpcId=='${gateway_vpc_id}' && AccepterVpcInfo.VpcId=='${worker_vpc_id}') || (RequesterVpcInfo.VpcId=='${worker_vpc_id}' && AccepterVpcInfo.VpcId=='${gateway_vpc_id}'))].VpcPeeringConnectionId" \
      --output text
  )"
  if [[ -n "$peering_text" && "$peering_text" != "None" ]]; then
    read -r -a peering_ids <<<"$peering_text"
    if [[ ${#peering_ids[@]} -eq 1 ]]; then
      peering_id="\"${peering_ids[0]}\""
      # Existing peering commonly has manually managed routes. Defaulting to
      # false avoids duplicate-route failures; users can import those routes
      # and change this to true when Terraform should own them.
      manage_vpc_routes="false"
    else
      printf 'error: multiple active peerings connect %s and %s: %s\n' \
        "$gateway_vpc_id" "$worker_vpc_id" "$peering_text" >&2
      exit 2
    fi
  fi

  certificate_text="$(
    aws_read acm list-certificates \
      --certificate-statuses ISSUED \
      --query "CertificateSummaryList[?DomainName=='*.${WORKER_DOMAIN}'].CertificateArn" \
      --output text
  )"
  if [[ -n "$certificate_text" && "$certificate_text" != "None" ]]; then
    read -r -a certificate_arns <<<"$certificate_text"
    if [[ ${#certificate_arns[@]} -eq 1 ]]; then
      certificate_arn="\"${certificate_arns[0]}\""
    else
      printf 'error: multiple issued *.%s certificates found; choose one in terraform.tfvars\n' \
        "$WORKER_DOMAIN" >&2
      exit 2
    fi
  fi

  printf 'Terraform input is ready. Paste stdout into terraform.tfvars,\n' >&2
  printf 'or redirect this command with: --tfvars > terraform.tfvars\n' >&2
  printf 'Review every GENERATED NOTE before running terraform plan.\n' >&2

  cat <<EOF
# Generated by discover-aws.sh for account $account_id in $REGION.
# Paste this entire output into terraform.tfvars.

aws_region = "$REGION"

gateway_vpc_id = "$gateway_vpc_id"
gateway_subnet_ids = [
EOF
  tfvars_list "$gateway_subnet_ids"
  cat <<EOF
]

worker_vpc_id = "$worker_vpc_id"
# GENERATED NOTE: this uses the GPU subnet in $worker_az. Add at most one
# worker-VPC subnet per availability zone if the NLB should span more zones.
worker_subnet_ids = [
  "$worker_subnet_id",
]

worker_instance_id                = "$GPU_INSTANCE_ID"
worker_instance_security_group_id = "$selected_security_group"

existing_vpc_peering_connection_id = $peering_id
# GENERATED NOTE: false is selected when an active peering already exists to
# avoid creating duplicate routes. Import existing routes and set true only
# when this Terraform state should manage them.
manage_vpc_routes = $manage_vpc_routes

# GENERATED NOTE: replace null with an existing reusable private-NLB security
# group ID only when adopting that group into this setup.
existing_nlb_security_group_id = null
manage_security_group_rules    = true

route53_zone_name = "$ROUTE53_ZONE"
worker_domain     = "$WORKER_DOMAIN"

# Reuses the one matching issued wildcard certificate when found; null makes
# Terraform create and DNS-validate a new certificate.
certificate_arn = $certificate_arn

EOF

  if [[ "$MODEL" == "8b" ]]; then
    cat <<'EOF'
workers = {
  "8b-a" = { node_port = 30003 }
  "8b-b" = { node_port = 30004 }
  "8b-c" = { node_port = 30005 }
  "8b-d" = { node_port = 30006 }
}
EOF
  else
    cat <<'EOF'
workers = {
  "27b-a" = { node_port = 30001 }
  "27b-b" = { node_port = 30002 }
}
EOF
  fi

  cat <<'EOF'
tags = {
  Project = "subconscious-inference"
}
EOF
}

if [[ "$TFVARS_MODE" == "true" ]]; then
  generate_tfvars
  exit 0
fi

section "AWS identity"
identity="$(
  aws_read sts get-caller-identity \
    --query '[Account,Arn]' \
    --output text
)"
IFS=$'\t' read -r account_id caller_arn <<<"$identity"
printf 'Account: %s\nCaller:  %s\nRegion:  %s\n' \
  "$account_id" "$caller_arn" "$REGION"

section "VPC inventory"
aws_read ec2 describe-vpcs \
  --query 'Vpcs[].{Name:Tags[?Key==`Name`]|[0].Value,VpcId:VpcId,Cidr:CidrBlock,State:State,Default:IsDefault}' \
  --output table

section "Subnet inventory"
aws_read ec2 describe-subnets \
  --query 'Subnets[].{Name:Tags[?Key==`Name`]|[0].Value,SubnetId:SubnetId,VpcId:VpcId,AZ:AvailabilityZone,Cidr:CidrBlock,Available:AvailableIpAddressCount,PublicIPv4:MapPublicIpOnLaunch}' \
  --output table

section "EKS cluster inventory"
aws_read eks list-clusters --query 'clusters' --output table

section "EC2 instance inventory"
aws_read ec2 describe-instances \
  --query 'Reservations[].Instances[?State.Name!=`terminated`].{Name:Tags[?Key==`Name`]|[0].Value,InstanceId:InstanceId,Type:InstanceType,State:State.Name,VpcId:VpcId,SubnetId:SubnetId,AZ:Placement.AvailabilityZone,SecurityGroups:join(`,`,SecurityGroups[].GroupId)}' \
  --output table

section "VPC peering inventory"
aws_read ec2 describe-vpc-peering-connections \
  --query 'VpcPeeringConnections[].{Name:Tags[?Key==`Name`]|[0].Value,Id:VpcPeeringConnectionId,Requester:RequesterVpcInfo.VpcId,Accepter:AccepterVpcInfo.VpcId,Status:Status.Code}' \
  --output table

section "Public Route 53 hosted zones"
aws_read route53 list-hosted-zones \
  --query 'HostedZones[?Config.PrivateZone==`false`].{Name:Name,Id:Id,Records:ResourceRecordSetCount}' \
  --output table

section "ACM certificates in selected region"
aws_read acm list-certificates \
  --certificate-statuses ISSUED PENDING_VALIDATION \
  --query 'CertificateSummaryList[].{Domain:DomainName,Status:Status,Arn:CertificateArn}' \
  --output table

if [[ -n "$ROUTE53_ZONE" ]]; then
  section "Selected Route 53 zone"
  aws_read route53 list-hosted-zones-by-name \
    --dns-name "$ROUTE53_ZONE" \
    --query "HostedZones[?Name=='${ROUTE53_ZONE}.']|[0].{Name:Name,Id:Id,Private:Config.PrivateZone,Records:ResourceRecordSetCount}" \
    --output table
fi

if [[ -n "$WORKER_DOMAIN" ]]; then
  section "Issued wildcard certificate for worker domain"
  aws_read acm list-certificates \
    --certificate-statuses ISSUED \
    --query "CertificateSummaryList[?DomainName=='*.${WORKER_DOMAIN}'].{Domain:DomainName,Arn:CertificateArn}" \
    --output table
fi

GATEWAY_VPC_ID=""
GATEWAY_SUBNET_IDS=""
GATEWAY_CLUSTER_SECURITY_GROUP=""

if [[ -n "$EKS_CLUSTER_NAME" ]]; then
  section "Selected EKS gateway"
  gateway_data="$(
    aws_read eks describe-cluster \
      --name "$EKS_CLUSTER_NAME" \
      --query 'cluster.[resourcesVpcConfig.vpcId,join(`,`,resourcesVpcConfig.subnetIds),resourcesVpcConfig.clusterSecurityGroupId,status]' \
      --output text
  )"
  IFS=$'\t' read -r \
    GATEWAY_VPC_ID \
    GATEWAY_SUBNET_IDS \
    GATEWAY_CLUSTER_SECURITY_GROUP \
    gateway_status <<<"$gateway_data"

  printf 'Cluster:                %s\n' "$EKS_CLUSTER_NAME"
  printf 'Status:                 %s\n' "$gateway_status"
  printf 'Gateway VPC:            %s\n' "$GATEWAY_VPC_ID"
  printf 'Gateway subnet IDs:     %s\n' "$GATEWAY_SUBNET_IDS"
  printf 'Cluster security group: %s\n' "$GATEWAY_CLUSTER_SECURITY_GROUP"

  section "Gateway VPC route tables"
  aws_read ec2 describe-route-tables \
    --filters "Name=vpc-id,Values=$GATEWAY_VPC_ID" \
    --query 'RouteTables[].{Name:Tags[?Key==`Name`]|[0].Value,RouteTableId:RouteTableId,Main:Associations[?Main==`true`]|[0].Main,AssociatedSubnets:join(`,`,Associations[].SubnetId)}' \
    --output table
fi

WORKER_VPC_ID=""
WORKER_SUBNET_ID=""
WORKER_AZ=""
WORKER_SECURITY_GROUP_IDS=""
WORKER_INSTANCE_STATE=""

if [[ -n "$GPU_INSTANCE_ID" ]]; then
  section "Selected GPU instance"
  worker_data="$(
    aws_read ec2 describe-instances \
      --instance-ids "$GPU_INSTANCE_ID" \
      --query 'Reservations[0].Instances[0].[VpcId,SubnetId,Placement.AvailabilityZone,join(`,`,SecurityGroups[].GroupId),State.Name]' \
      --output text
  )"
  IFS=$'\t' read -r \
    WORKER_VPC_ID \
    WORKER_SUBNET_ID \
    WORKER_AZ \
    WORKER_SECURITY_GROUP_IDS \
    WORKER_INSTANCE_STATE <<<"$worker_data"

  printf 'Instance:               %s\n' "$GPU_INSTANCE_ID"
  printf 'State:                  %s\n' "$WORKER_INSTANCE_STATE"
  printf 'Worker VPC:             %s\n' "$WORKER_VPC_ID"
  printf 'Worker subnet:          %s\n' "$WORKER_SUBNET_ID"
  printf 'Worker availability zone: %s\n' "$WORKER_AZ"
  printf 'Attached security groups: %s\n' "$WORKER_SECURITY_GROUP_IDS"

  section "Worker VPC subnets"
  aws_read ec2 describe-subnets \
    --filters "Name=vpc-id,Values=$WORKER_VPC_ID" \
    --query 'Subnets[].{Name:Tags[?Key==`Name`]|[0].Value,SubnetId:SubnetId,AZ:AvailabilityZone,Cidr:CidrBlock,Available:AvailableIpAddressCount,PublicIPv4:MapPublicIpOnLaunch}' \
    --output table

  section "Worker VPC route tables"
  aws_read ec2 describe-route-tables \
    --filters "Name=vpc-id,Values=$WORKER_VPC_ID" \
    --query 'RouteTables[].{Name:Tags[?Key==`Name`]|[0].Value,RouteTableId:RouteTableId,Main:Associations[?Main==`true`]|[0].Main,AssociatedSubnets:join(`,`,Associations[].SubnetId)}' \
    --output table

  section "Worker VPC security groups"
  aws_read ec2 describe-security-groups \
    --filters "Name=vpc-id,Values=$WORKER_VPC_ID" \
    --query 'SecurityGroups[].{Name:GroupName,Id:GroupId,Description:Description}' \
    --output table

  section "Public NodePort rules on attached GPU security groups"
  public_nodeport_rules="$(
    aws_read ec2 describe-security-group-rules \
      --filters "Name=group-id,Values=$WORKER_SECURITY_GROUP_IDS" \
      --query 'SecurityGroupRules[?IsEgress==`false` && (CidrIpv4==`0.0.0.0/0` || CidrIpv6==`::/0`) && (IpProtocol==`"-1"` || (FromPort<=`32767` && ToPort>=`30000`))].{Group:GroupId,Rule:SecurityGroupRuleId,Protocol:IpProtocol,From:FromPort,To:ToPort,IPv4:CidrIpv4,IPv6:CidrIpv6}' \
      --output table
  )"
  if [[ -n "$public_nodeport_rules" ]]; then
    printf '%s\n' "$public_nodeport_rules"
    printf 'WARNING: remove public rules overlapping TCP 30000-32767.\n'
  else
    printf 'No public ingress rule overlaps TCP 30000-32767.\n'
  fi
fi

if [[ -n "$GATEWAY_VPC_ID" && -n "$WORKER_VPC_ID" ]]; then
  section "Peering between selected VPCs"
  aws_read ec2 describe-vpc-peering-connections \
    --query "VpcPeeringConnections[?(RequesterVpcInfo.VpcId=='${GATEWAY_VPC_ID}' && AccepterVpcInfo.VpcId=='${WORKER_VPC_ID}') || (RequesterVpcInfo.VpcId=='${WORKER_VPC_ID}' && AccepterVpcInfo.VpcId=='${GATEWAY_VPC_ID}')].{Id:VpcPeeringConnectionId,Requester:RequesterVpcInfo.VpcId,Accepter:AccepterVpcInfo.VpcId,Status:Status.Code}" \
    --output table

  section "Terraform input starter"
  cat <<EOF
aws_region = "$REGION"

gateway_vpc_id = "$GATEWAY_VPC_ID"
gateway_subnet_ids = [
EOF
  tfvars_list "$GATEWAY_SUBNET_IDS"
  cat <<EOF
]

worker_vpc_id = "$WORKER_VPC_ID"
# This safe starter uses the GPU instance subnet. Add at most one worker-VPC
# subnet per availability zone if the NLB should span additional zones.
worker_subnet_ids = [
  "$WORKER_SUBNET_ID",
]

worker_instance_id = "$GPU_INSTANCE_ID"
EOF

  if [[ "$WORKER_SECURITY_GROUP_IDS" == *,* ]]; then
    printf '# Choose one security group attached to the GPU instance: %s\n' \
      "$WORKER_SECURITY_GROUP_IDS"
    printf 'worker_instance_security_group_id = "sg-CHOOSE_ONE"\n'
  else
    printf 'worker_instance_security_group_id = "%s"\n' \
      "$WORKER_SECURITY_GROUP_IDS"
  fi

  if [[ -n "$ROUTE53_ZONE" ]]; then
    printf '\nroute53_zone_name = "%s"\n' "$ROUTE53_ZONE"
  else
    printf '\nroute53_zone_name = "REPLACE_WITH_PUBLIC_ZONE"\n'
  fi

  if [[ -n "$WORKER_DOMAIN" ]]; then
    printf 'worker_domain     = "%s"\n' "$WORKER_DOMAIN"
  else
    printf 'worker_domain     = "workers.REPLACE_WITH_PUBLIC_ZONE"\n'
  fi

  cat <<'EOF'

# Add the workers map for the selected 8B or 27B profile.
EOF
else
  section "Next command"
  echo "Pass both --gpu-instance-id and --eks-cluster to print a Terraform input starter."
fi
