# shellcheck shell=bash
# AWS provider: EC2 GPU instances with the Deep Learning AMI (Ubuntu).
# Environment:
#   AWS_REGION          region (default us-east-1)
#   AWS_INSTANCE_TYPE   override the topology -> instance type map
#   AMI_ID              override the DLAMI (default: latest via SSM parameter)
#   AWS_AMI_SSM_PARAM   SSM parameter used for the default AMI lookup
#   KEY_NAME            EC2 key pair name (default: SSH_KEY basename)
#   SUBNET_ID           subnet for the instance (default: default VPC subnet)
#   SG_ID               security group (default: one created per instance, SSH + NodePorts)
#   DISK_GB             root volume size (default 1024)
# Notes: only topologies AWS actually sells are mapped; anything else
# requires AWS_INSTANCE_TYPE.
AWS_REGION="${AWS_REGION:-us-east-1}"
DISK_GB="${DISK_GB:-1024}"
SSH_USER="${SSH_USER:-ubuntu}"
AWS_AMI_SSM_PARAM="${AWS_AMI_SSM_PARAM:-/aws/service/deeplearning/ami/x86_64/base-oss-nvidia-driver-gpu-ubuntu-2204/latest/ami-id}"

provider_help() {
  cat <<'EOF'
AWS environment:
  AWS_REGION, AWS_INSTANCE_TYPE, AMI_ID, AWS_AMI_SSM_PARAM, KEY_NAME,
  SUBNET_ID, SG_ID, DISK_GB, SSH_KEY, SSH_USER
The instance uses the Ubuntu Deep Learning AMI (NVIDIA drivers preinstalled)
and opens TCP 22 plus NodePorts 30001-30006.
EOF
}

resolve_instance_type() {
  local gpu="$1" count="$2"
  if [[ -n "${AWS_INSTANCE_TYPE:-}" ]]; then
    INSTANCE_TYPE="$AWS_INSTANCE_TYPE"
    return
  fi
  case "${gpu}-${count}" in
    l4-1) INSTANCE_TYPE="g6.xlarge" ;;
    l40s-1) INSTANCE_TYPE="g6e.xlarge" ;;
    a100-80gb-1) INSTANCE_TYPE="p4de.8xlarge" ;;
    a100-80gb-2) INSTANCE_TYPE="p4de.16xlarge" ;;
    a100-80gb-8) INSTANCE_TYPE="p4de.24xlarge" ;;
    h100-80gb-8) INSTANCE_TYPE="p5.48xlarge" ;;
    h200-8) INSTANCE_TYPE="p5e.48xlarge" ;;
    *)
      die "no default AWS instance type for ${gpu} x ${count}; set AWS_INSTANCE_TYPE (AWS sells this topology only in specific sizes/regions)"
      ;;
  esac
  log "instance type: ${INSTANCE_TYPE}"
}

provision() {
  have aws || die "install and configure the AWS CLI"

  local ami subnet vpc sg instance_id
  ami="${AMI_ID:-}"
  if [[ -z "$ami" ]]; then
    ami="$(aws ssm get-parameter \
      --region "$AWS_REGION" \
      --name "$AWS_AMI_SSM_PARAM" \
      --query 'Parameter.Value' --output text 2>/dev/null || true)"
    [[ -n "$ami" && "$ami" != "None" ]] ||
      die "could not resolve the default DLAMI; set AMI_ID to an Ubuntu Deep Learning AMI in ${AWS_REGION}"
  fi

  subnet="${SUBNET_ID:-}"
  if [[ -z "$subnet" ]]; then
    subnet="$(aws ec2 describe-subnets \
      --region "$AWS_REGION" \
      --filters 'Name=default-for-az,Values=true' \
      --query 'Subnets[0].SubnetId' --output text)"
    [[ -n "$subnet" && "$subnet" != "None" ]] ||
      die "no default subnet found; set SUBNET_ID"
  fi

  sg="${SG_ID:-}"
  if [[ -z "$sg" ]]; then
    vpc="$(aws ec2 describe-subnets \
      --region "$AWS_REGION" --subnet-ids "$subnet" \
      --query 'Subnets[0].VpcId' --output text)"
    sg="$(aws ec2 create-security-group \
      --region "$AWS_REGION" \
      --group-name "${INSTANCE_NAME}-sg" \
      --description "subconscious worker deploy" \
      --vpc-id "$vpc" --query 'GroupId' --output text)"
    aws ec2 authorize-security-group-ingress --region "$AWS_REGION" --group-id "$sg" \
      --protocol tcp --port 22 --cidr 0.0.0.0/0 >/dev/null
    aws ec2 authorize-security-group-ingress --region "$AWS_REGION" --group-id "$sg" \
      --protocol tcp --port 30001-30006 --cidr 0.0.0.0/0 >/dev/null
  fi

  instance_id="$(aws ec2 run-instances \
    --region "$AWS_REGION" \
    --image-id "$ami" \
    --instance-type "$INSTANCE_TYPE" \
    --key-name "${KEY_NAME:-$(basename "$SSH_KEY")}" \
    --subnet-id "$subnet" \
    --security-group-ids "$sg" \
    --block-device-mappings "DeviceName=/dev/sda1,Ebs={VolumeSize=${DISK_GB},VolumeType=gp3}" \
    --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=${INSTANCE_NAME}}]" \
    --query 'Instances[0].InstanceId' --output text)"

  log "waiting for ${instance_id} to run"
  aws ec2 wait instance-running --region "$AWS_REGION" --instance-ids "$instance_id"
  SSH_HOST="$(aws ec2 describe-instances \
    --region "$AWS_REGION" --instance-ids "$instance_id" \
    --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)"
  [[ -n "$SSH_HOST" && "$SSH_HOST" != "None" ]] ||
    die "instance has no public IP; set SUBNET_ID to a public subnet or use --instance-ip"
  log "instance running at ${SSH_HOST}"
}
