#!/usr/bin/env bash
# Add this computer's current public IPv4 /32 to the AWS dashboard allow rule.
#
# The EKS API is normally reachable only from the bootstrap EC2. This script
# logs the operator into AWS locally, detects the local public IP, discovers
# that EC2 from the cluster endpoint allowlist, and patches the Kubernetes
# Ingress through SSM. AWS Load Balancer Controller then reconciles the ALB.
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
  ./scripts/add-dashboard-ip.sh \
    <INFRA_DEPLOY_NAME> \
    <GATEWAY_DISTR_DEPLOYMENT_NAME>

Example:
  ./scripts/add-dashboard-ip.sh \
    api-gateway-awsgateway \
    api-gateway-awsgateway

Environment overrides:
  AWS_REGION   AWS region (default: us-east-2)
  INSTANCE_ID  Bootstrap EC2 instance id (normally auto-discovered)

The dashboard ALB rule supports at most three source IPv4 addresses.
EOF
}

if [[ $# -ne 2 ]]; then
  usage
  exit 2
fi

CLUSTER_NAME="$1"
GATEWAY_NAME="$2"
REGION="${AWS_REGION:-us-east-2}"

for value in "${CLUSTER_NAME}" "${GATEWAY_NAME}"; do
  if [[ ! "${value}" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]]; then
    echo "ERROR: deployment names must be lowercase DNS labels (got: ${value})" >&2
    exit 2
  fi
done
if [[ ! "${REGION}" =~ ^[a-z]{2}(-gov)?-[a-z]+-[0-9]+$ ]]; then
  echo "ERROR: invalid AWS_REGION: ${REGION}" >&2
  exit 2
fi

need aws
need curl
need jq
need python3

echo "[dashboard-ip] opening AWS login"
aws login
aws sts get-caller-identity --output json >/dev/null

PUBLIC_IP="$(
  curl --fail --silent --show-error --max-time 15 \
    https://checkip.amazonaws.com \
    | tr -d '[:space:]'
)"
python3 - "${PUBLIC_IP}" <<'PY'
import ipaddress
import sys

address = ipaddress.ip_address(sys.argv[1])
if address.version != 4:
    raise SystemExit("current public address is not IPv4")
PY
PUBLIC_CIDR="${PUBLIC_IP}/32"
echo "[dashboard-ip] current public IPv4: ${PUBLIC_CIDR}"

INSTANCE_ID="${INSTANCE_ID:-}"
if [[ -z "${INSTANCE_ID}" ]]; then
  endpoint_cidrs="$(
    aws eks describe-cluster \
      --region "${REGION}" \
      --name "${CLUSTER_NAME}" \
      --query 'cluster.resourcesVpcConfig.publicAccessCidrs' \
      --output json
  )"
  bootstrap_ip="$(
    jq -r '[.[] | select(endswith("/32"))][0] // empty | sub("/32$"; "")' \
      <<<"${endpoint_cidrs}"
  )"
  if [[ -z "${bootstrap_ip}" ]]; then
    echo "ERROR: could not discover a bootstrap /32 from the EKS endpoint allowlist" >&2
    echo "Set INSTANCE_ID to the SSM-managed bootstrap EC2 instance." >&2
    exit 1
  fi
  INSTANCE_ID="$(
    aws ec2 describe-addresses \
      --region "${REGION}" \
      --filters "Name=public-ip,Values=${bootstrap_ip}" \
      --query 'Addresses[0].InstanceId' \
      --output text
  )"
  if [[ -z "${INSTANCE_ID}" || "${INSTANCE_ID}" == "None" ]]; then
    echo "ERROR: no EC2 instance owns EKS endpoint address ${bootstrap_ip}" >&2
    echo "Set INSTANCE_ID to the SSM-managed bootstrap EC2 instance." >&2
    exit 1
  fi
fi

ping_status="$(
  aws ssm describe-instance-information \
    --region "${REGION}" \
    --filters "Key=InstanceIds,Values=${INSTANCE_ID}" \
    --query 'InstanceInformationList[0].PingStatus' \
    --output text
)"
if [[ "${ping_status}" != "Online" ]]; then
  echo "ERROR: bootstrap instance ${INSTANCE_ID} is not SSM Online" >&2
  exit 1
fi
echo "[dashboard-ip] using bootstrap instance ${INSTANCE_ID}"

CLUSTER_Q="$(printf '%q' "${CLUSTER_NAME}")"
GATEWAY_Q="$(printf '%q' "${GATEWAY_NAME}")"
REGION_Q="$(printf '%q' "${REGION}")"
CIDR_Q="$(printf '%q' "${PUBLIC_CIDR}")"
REMOTE="set -euo pipefail
export HOME=/root
export KUBECONFIG=/root/.kube/config
export AWS_REGION=${REGION_Q}
CLUSTER=${CLUSTER_Q}
GATEWAY=${GATEWAY_Q}
CIDR=${CIDR_Q}

aws eks update-kubeconfig --name \"\${CLUSTER}\" --region \"\${AWS_REGION}\" >/dev/null
ingress_json=\$(kubectl -n \"\${GATEWAY}\" get ingress \"\${GATEWAY}\" -o json)

if ! jq -e '
  any(.spec.rules[].http.paths[];
    .path == \"/dashboard*\"
    and .backend.service.name == \"dashboard-allow\"
  )
' >/dev/null <<<\"\${ingress_json}\"; then
  echo 'ERROR: dashboard allow path is not installed on the Ingress' >&2
  echo 'Deploy a chart containing ingress.dashboard.allowedSourceCidrs first.' >&2
  exit 1
fi

condition=\$(
  jq -r '.metadata.annotations[\"alb.ingress.kubernetes.io/conditions.dashboard-allow\"] // empty' \
    <<<\"\${ingress_json}\"
)
if [[ -z \"\${condition}\" ]]; then
  echo 'ERROR: dashboard source-IP condition annotation is missing' >&2
  exit 1
fi

updated=\$(
  jq -ce --arg cidr \"\${CIDR}\" '
    if length != 1 or .[0].field != \"source-ip\" then
      error(\"unexpected dashboard source condition shape\")
    else
      (. [0].sourceIpConfig.values + [\$cidr] | unique) as \$values
      | if (\$values | length) > 3 then
          error(\"dashboard allow rule already has three source IPs\")
        else
          .[0].sourceIpConfig.values = \$values
        end
    end
  ' <<<\"\${condition}\"
)

kubectl -n \"\${GATEWAY}\" annotate ingress \"\${GATEWAY}\" \
  \"alb.ingress.kubernetes.io/conditions.dashboard-allow=\${updated}\" \
  --overwrite >/dev/null

alb_dns=\$(
  kubectl -n \"\${GATEWAY}\" get ingress \"\${GATEWAY}\" \
    -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'
)
echo \"ALB_DNS=\${alb_dns}\"
echo \"SOURCE_CIDRS=\$(jq -r '.[0].sourceIpConfig.values | join(\",\")' <<<\"\${updated}\")\"
"

parameters="$(jq -nc --arg command "${REMOTE}" '{commands:[$command]}')"
command_id="$(
  aws ssm send-command \
    --region "${REGION}" \
    --instance-ids "${INSTANCE_ID}" \
    --document-name AWS-RunShellScript \
    --timeout-seconds 180 \
    --parameters "${parameters}" \
    --query 'Command.CommandId' \
    --output text
)"
echo "[dashboard-ip] SSM command: ${command_id}"
aws ssm wait command-executed \
  --region "${REGION}" \
  --command-id "${command_id}" \
  --instance-id "${INSTANCE_ID}" 2>/dev/null || true

invocation="$(
  aws ssm get-command-invocation \
    --region "${REGION}" \
    --command-id "${command_id}" \
    --instance-id "${INSTANCE_ID}" \
    --output json
)"
stdout="$(jq -r '.StandardOutputContent' <<<"${invocation}")"
stderr="$(jq -r '.StandardErrorContent' <<<"${invocation}")"
[[ -z "${stdout}" ]] || printf '%s\n' "${stdout}"
[[ -z "${stderr}" ]] || printf '%s\n' "${stderr}" >&2
if [[ "$(jq -r '.Status' <<<"${invocation}")" != "Success" ]]; then
  echo "ERROR: remote Ingress update failed" >&2
  exit 1
fi

alb_dns="$(awk -F= '/^ALB_DNS=/{print $2}' <<<"${stdout}" | tail -1)"
source_cidrs="$(awk -F= '/^SOURCE_CIDRS=/{print $2}' <<<"${stdout}" | tail -1)"
if [[ -z "${alb_dns}" ]]; then
  echo "ERROR: Ingress has no ALB hostname" >&2
  exit 1
fi

alb_arn="$(
  aws elbv2 describe-load-balancers \
    --region "${REGION}" \
    --query "LoadBalancers[?DNSName=='${alb_dns}'].LoadBalancerArn | [0]" \
    --output text
)"
listener_arn="$(
  aws elbv2 describe-listeners \
    --region "${REGION}" \
    --load-balancer-arn "${alb_arn}" \
    --query "Listeners[?Port==\`443\`].ListenerArn | [0]" \
    --output text
)"

reconciled=0
for _ in $(seq 1 30); do
  rules="$(
    aws elbv2 describe-rules \
      --region "${REGION}" \
      --listener-arn "${listener_arn}" \
      --output json
  )"
  if jq -e --arg cidr "${PUBLIC_CIDR}" '
    any(.Rules[];
      any(.Conditions[];
        .Field == "path-pattern"
        and (.PathPatternConfig.Values | index("/dashboard*"))
      )
      and any(.Conditions[];
        .Field == "source-ip"
        and (.SourceIpConfig.Values | index($cidr))
      )
      and .Actions[0].Type == "forward"
    )
  ' >/dev/null <<<"${rules}"; then
    reconciled=1
    break
  fi
  sleep 2
done

if [[ "${reconciled}" -ne 1 ]]; then
  echo "ERROR: ALB did not reconcile ${PUBLIC_CIDR} within 60 seconds" >&2
  exit 1
fi

echo "[dashboard-ip] ALB now allows: ${source_cidrs}"
echo "[dashboard-ip] Persist in the private Distr env as:"
echo "DASHBOARD_ALLOWED_IPS=${source_cidrs//\/32/}"
