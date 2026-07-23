#!/usr/bin/env bash
# Bootstrap the Distr Docker agent EC2 host (laptop-applied, idempotent).
# Terraform keeps the same instance; host Docker/compose is ensured via SSM.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TF_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"
cd "${TF_DIR}"

bootstrap_need terraform
bootstrap_need aws
bootstrap_need jq

if [[ ! -f terraform.tfvars && -f terraform.tfvars.example ]]; then
  echo "NOTE: no terraform.tfvars — using defaults / example values"
fi

if [[ ! -f backend.tf && -f backend.tf.example ]]; then
  echo "NOTE: no backend.tf — using local state (copy backend.tf.example for S3)"
fi

echo "== terraform init =="
terraform init -input=false

echo "== terraform apply =="
terraform apply -input=false -auto-approve

INSTANCE_ID="$(terraform output -raw instance_id)"
EIP="$(terraform output -raw eip)"
REGION="$(terraform output -raw aws_region)"
SSM="$(terraform output -raw ssm_start_session_command)"

echo "== ensure host (idempotent Docker/compose) =="
"${SCRIPT_DIR}/ensure-host.sh"

cat <<EOF

== Docker agent host ready ==

  instance_id:  ${INSTANCE_ID}
  eip:          ${EIP}
  aws_region:   ${REGION}

Next:

  1. In Distr Hub, create/open the api-gateway-infra Docker deployment and copy
     the agent connect URL (https://…/api/v1/connect?…).

  2. Install the agent on this host (paste the Hub connect URL only):

       ./scripts/run-agent.sh 'https://app.distr.sh/api/v1/connect?targetId=…&targetSecret=…'

  3. Hub infra env: no AWS access keys; GATEWAY_AUTO_DEPLOY=false until the
     K8s agent target exists (template.env defaults are otherwise fine).

  4. After EKS exists, paste the Hub Kubernetes-agent connect command:

       ./scripts/connect-k8s-agent.sh \
         <INFRA_DEPLOY_NAME> \
         'kubectl apply -n <GATEWAY_DISTR_DEPLOYMENT_NAME> -f "https://app.distr.sh/api/v1/connect?…"'

     (The first argument is the EKS cluster name. Agent pods run in the gateway
      namespace; this host only runs kubectl over SSM.)

  Optional interactive shell:
    ${SSM}

  Repair Docker/compose/kubectl without recreating the instance:
    ./scripts/ensure-host.sh

EOF
