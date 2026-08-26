#!/usr/bin/env bash
# SSM onto the docker-agent EC2: interactive shell, env resolution, one-shot SQL.
#
# Day-0 EKS API is CIDR-locked to this host. Prefer kubectl from here over
# laptop kubeconfig. Distinct from connect-k8s-agent.sh (agent install).
#
#   ./scripts/connect.sh help
#   ./scripts/connect.sh shell [<INFRA_DEPLOY_NAME>]
#   ./scripts/connect.sh env <INFRA_DEPLOY_NAME>
#   ./scripts/connect.sh sql <INFRA_DEPLOY_NAME> --ns <GATEWAY_NS> --file <sql>
#   ./scripts/connect.sh <INFRA_DEPLOY_NAME>    # same as shell NAME
#
# Never prints SecretString or the database URL. Do not run bootstrap.sh here.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TF_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

connect_help() {
  cat >&2 <<'EOF'
usage:
  ./scripts/connect.sh help
  ./scripts/connect.sh shell [<INFRA_DEPLOY_NAME>]
  ./scripts/connect.sh env <INFRA_DEPLOY_NAME>
  ./scripts/connect.sh sql <INFRA_DEPLOY_NAME> --ns <GATEWAY_NS> --file <sql-file>
  ./scripts/connect.sh <INFRA_DEPLOY_NAME>          # same as: shell NAME
  ./scripts/connect.sh                              # same as: shell (INSTANCE_ID or terraform)

INFRA_DEPLOY_NAME  Distr Docker / Terraform name prefix (EKS cluster, EC2 Name tag)
GATEWAY_NS         Kubernetes namespace (--ns is required for sql; do not guess)

What must be true
  Laptop
    - aws CLI with credentials for ec2:DescribeInstances and SSM
      (ssm:SendCommand / ssm:GetCommandInvocation; shell also needs ssm:StartSession)
    - AWS_REGION set (example: us-east-2). Terraform state is optional if the
      docker-agent Name tag is <INFRA_DEPLOY_NAME>-docker-agent
    - session-manager-plugin — shell only
      https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html
    - jq — env/sql wait on SSM command status
  Host
    - exactly one running EC2 named <INFRA_DEPLOY_NAME>-docker-agent, SSM Online
    - after shell: sudo -i, then export HOME=/root KUBECONFIG=/root/.kube/config
      (SSM user is often ssm-user; kubeconfig is root's)
  sql
    - --ns is the gateway Helm namespace (GATEWAY_DISTR_DEPLOYMENT_NAME), not
      the infra name. That namespace must contain Secret gateway-secrets with
      SUBCONSCIOUS_GATEWAY_DATABASE_URL
    - the cluster can pull postgres:16-alpine
    - pass SQL as --file (example: scripts/sql/usage-lag.sql)

Do not
  - run ./scripts/bootstrap.sh against a live deploy
  - aws secretsmanager get-secret-value / echo the DB URL
  - kubectl exec into a gateway pod expecting a shell
EOF
}

# Job spec mounted with a ConfigMap of SQL. Must never embed a password or URL.
connect_sql_job_yaml() {
  local job_name="$1"
  local config_map="$2"
  sed -e "s/__JOB__/${job_name}/g" -e "s/__CM__/${config_map}/g" <<'EOF'
apiVersion: batch/v1
kind: Job
metadata:
  name: __JOB__
  labels:
    app.kubernetes.io/name: gateway-sql
spec:
  ttlSecondsAfterFinished: 60
  backoffLimit: 0
  template:
    spec:
      restartPolicy: Never
      containers:
      - name: psql
        image: postgres:16-alpine
        envFrom:
        - secretRef:
            name: gateway-secrets
        command: ["sh", "-c"]
        args:
        - |
          set -euo pipefail
          psql "$SUBCONSCIOUS_GATEWAY_DATABASE_URL" -v ON_ERROR_STOP=1 \
            -c "SET statement_timeout = '15s'" \
            -f /sql/query.sql
        volumeMounts:
        - name: sql
          mountPath: /sql
          readOnly: true
      volumes:
      - name: sql
        configMap:
          name: __CM__
EOF
}

# Parse CLI. Sets COMMAND, INFRA_DEPLOY_NAME, GATEWAY_NS, SQL_FILE, SQL_TEXT.
# Return 0 on success / help, 2 on usage error. Does not touch AWS.
connect_parse_args() {
  COMMAND=""
  INFRA_DEPLOY_NAME=""
  GATEWAY_NS=""
  SQL_FILE=""
  SQL_TEXT=""

  if [[ $# -eq 0 ]]; then
    COMMAND="shell"
    return 0
  fi

  if [[ "${1}" == "-h" || "${1}" == "--help" || "${1}" == "help" ]]; then
    COMMAND="help"
    return 0
  fi

  case "${1}" in
    shell|env|sql)
      COMMAND="${1}"
      shift
      ;;
    -*)
      echo "ERROR: unknown flag ${1}" >&2
      connect_help
      return 2
      ;;
    *)
      COMMAND="shell"
      ;;
  esac

  if [[ "${COMMAND}" == "shell" && $# -gt 0 ]]; then
    INFRA_DEPLOY_NAME="${1}"
    shift
    if [[ $# -gt 0 ]]; then
      echo "ERROR: unexpected extra argument: ${1}" >&2
      return 2
    fi
  elif [[ "${COMMAND}" == "env" ]]; then
    if [[ $# -lt 1 ]]; then
      echo "ERROR: env requires <INFRA_DEPLOY_NAME>" >&2
      connect_help
      return 2
    fi
    INFRA_DEPLOY_NAME="${1}"
    shift
    if [[ $# -gt 0 ]]; then
      echo "ERROR: unexpected extra argument: ${1}" >&2
      return 2
    fi
  elif [[ "${COMMAND}" == "sql" ]]; then
    if [[ $# -lt 1 ]]; then
      echo "ERROR: sql requires <INFRA_DEPLOY_NAME>" >&2
      connect_help
      return 2
    fi
    INFRA_DEPLOY_NAME="${1}"
    shift
    while [[ $# -gt 0 ]]; do
      case "${1}" in
        --ns)
          GATEWAY_NS="${2:-}"
          if [[ -z "${GATEWAY_NS}" ]]; then
            echo "ERROR: --ns requires a namespace" >&2
            return 2
          fi
          shift 2
          ;;
        --file)
          SQL_FILE="${2:-}"
          if [[ -z "${SQL_FILE}" ]]; then
            echo "ERROR: --file requires a path" >&2
            return 2
          fi
          shift 2
          ;;
        -*)
          echo "ERROR: unknown flag ${1}" >&2
          return 2
          ;;
        *)
          echo "ERROR: pass SQL as --file <path> (got: ${1})" >&2
          return 2
          ;;
      esac
    done
  fi

  if [[ -n "${INFRA_DEPLOY_NAME}" ]] && ! bootstrap_dns1123_ok "${INFRA_DEPLOY_NAME}"; then
    echo "ERROR: INFRA_DEPLOY_NAME must be a DNS-1123 label (got: ${INFRA_DEPLOY_NAME})" >&2
    return 2
  fi

  if [[ "${COMMAND}" == "sql" ]]; then
    if [[ -z "${GATEWAY_NS}" ]]; then
      echo "ERROR: sql requires --ns <GATEWAY_NS> (do not guess the namespace)" >&2
      return 2
    fi
    if ! bootstrap_dns1123_ok "${GATEWAY_NS}"; then
      echo "ERROR: --ns must be a DNS-1123 label (got: ${GATEWAY_NS})" >&2
      return 2
    fi
    if [[ -z "${SQL_FILE}" ]]; then
      echo "ERROR: sql requires --file <path>" >&2
      return 2
    fi
    if [[ ! -f "${SQL_FILE}" || ! -r "${SQL_FILE}" ]]; then
      echo "ERROR: SQL file is not readable: ${SQL_FILE}" >&2
      return 2
    fi
    SQL_TEXT="$(cat "${SQL_FILE}")"
    if [[ -z "${SQL_TEXT}" ]]; then
      echo "ERROR: SQL file is empty: ${SQL_FILE}" >&2
      return 2
    fi
  elif [[ -n "${GATEWAY_NS}" || -n "${SQL_FILE}" ]]; then
    echo "ERROR: --ns / --file are only valid with sql" >&2
    return 2
  fi
  return 0
}

connect_require_region() {
  REGION="${AWS_REGION:-}"
  if [[ -z "${REGION}" && -d "${TF_DIR}" ]] && command -v terraform >/dev/null 2>&1; then
    REGION="$(terraform -chdir="${TF_DIR}" output -raw aws_region 2>/dev/null || true)"
  fi
  if [[ -z "${REGION}" ]]; then
    echo "ERROR: set AWS_REGION (example: us-east-2)" >&2
    return 2
  fi
}

# INSTANCE_ID from env, terraform, or EC2 Name=<INFRA>-docker-agent.
connect_resolve_host() {
  connect_require_region || return 2
  INSTANCE_ID="${INSTANCE_ID:-}"
  if [[ -z "${INSTANCE_ID}" && -d "${TF_DIR}" ]] && command -v terraform >/dev/null 2>&1; then
    INSTANCE_ID="$(terraform -chdir="${TF_DIR}" output -raw instance_id 2>/dev/null || true)"
  fi
  if [[ -z "${INSTANCE_ID}" && -n "${INFRA_DEPLOY_NAME}" ]]; then
    bootstrap_resolve_instance_by_name "${INFRA_DEPLOY_NAME}" || return 1
  fi
  if [[ -z "${INSTANCE_ID}" ]]; then
    echo "ERROR: could not resolve instance_id (pass INFRA_DEPLOY_NAME, set INSTANCE_ID, or run bootstrap)" >&2
    return 1
  fi
}

connect_print_env() {
  local suggested_ns="${INFRA_DEPLOY_NAME%-infra}"
  cat <<EOF
INSTANCE_ID=${INSTANCE_ID}
AWS_REGION=${REGION}
# shell
INSTANCE_ID=${INSTANCE_ID} AWS_REGION=${REGION} ${SCRIPT_DIR}/connect.sh shell ${INFRA_DEPLOY_NAME}

# on the box (SSM user is often ssm-user; kubeconfig is root's)
sudo -i
export HOME=/root KUBECONFIG=/root/.kube/config

# sql requires an explicit gateway namespace (hint only; do not guess)
# ${SCRIPT_DIR}/connect.sh sql ${INFRA_DEPLOY_NAME} --ns ${suggested_ns} --file ${SCRIPT_DIR}/sql/usage-lag.sql
EOF
}

connect_refresh_kubeconfig() {
  local cluster_q region_q remote
  cluster_q="$(printf '%q' "${INFRA_DEPLOY_NAME}")"
  region_q="$(printf '%q' "${REGION}")"
  remote="set -euo pipefail
export HOME=/root
export KUBECONFIG=/root/.kube/config
export AWS_REGION=${region_q}
CLUSTER=${cluster_q}

echo \"[connect] update-kubeconfig cluster=\${CLUSTER} region=\${AWS_REGION}\"
aws eks update-kubeconfig --name \"\${CLUSTER}\" --region \"\${AWS_REGION}\"
echo \"[connect] kubeconfig ready\"
"
  echo "[connect] refreshing kubeconfig for cluster ${INFRA_DEPLOY_NAME}…"
  bootstrap_ssm_run "${remote}" 120 "connect-kubeconfig"
}

connect_print_shell_hints() {
  local ns_hint="${GATEWAY_NS:-<GATEWAY_DISTR_DEPLOYMENT_NAME>}"
  cat >&2 <<EOF
[connect] SSM session → ${INSTANCE_ID} (${REGION})
On the box:

  # kubeconfig (HOME is often unset under SSM)
  export HOME=/root KUBECONFIG=/root/.kube/config

  # infra Docker agent / runner
  docker ps -a --filter name=runner
  docker logs --tail 200 distr-*-runner-1

  # gateway namespace (separate from the infra DEPLOY_NAME / cluster)
  kubectl -n ${ns_hint} get pods,deploy,svc
  kubectl -n ${ns_hint} logs deploy/<name> --tail=200
  kubectl -n ${ns_hint} describe pod/<name>

  # identity bootstrap (see ol-runbook api-gateway/aws/troubleshooting.md)
  kubectl -n ${ns_hint} exec -it deploy/<adapter> -- ops-cli identity bootstrap …

EOF
}

connect_run_sql() {
  bootstrap_need aws
  bootstrap_need jq
  bootstrap_need base64
  local sql_b64 job_name remote
  sql_b64="$(printf '%s' "${SQL_TEXT}" | base64 | tr -d '\n')"
  job_name="gateway-sql-$(date +%s)"

  remote="NS=$(printf '%q' "${GATEWAY_NS}")
JOB=$(printf '%q' "${job_name}")
SQL_B64=$(printf '%q' "${sql_b64}")
$(cat <<'REMOTE'
set -euo pipefail
export HOME=/root
export KUBECONFIG=/root/.kube/config
printf '%s' "${SQL_B64}" | base64 -d >"/tmp/${JOB}.sql"
kubectl -n "${NS}" create configmap "${JOB}" --from-file=query.sql="/tmp/${JOB}.sql"
cat <<YAML | kubectl -n "${NS}" apply -f -
apiVersion: batch/v1
kind: Job
metadata:
  name: ${JOB}
  labels:
    app.kubernetes.io/name: gateway-sql
spec:
  ttlSecondsAfterFinished: 60
  backoffLimit: 0
  template:
    spec:
      restartPolicy: Never
      containers:
      - name: psql
        image: postgres:16-alpine
        envFrom:
        - secretRef:
            name: gateway-secrets
        command: ["sh", "-c"]
        args:
        - |
          set -euo pipefail
          psql "\$SUBCONSCIOUS_GATEWAY_DATABASE_URL" -v ON_ERROR_STOP=1 \
            -c "SET statement_timeout = '15s'" \
            -f /sql/query.sql
        volumeMounts:
        - name: sql
          mountPath: /sql
          readOnly: true
      volumes:
      - name: sql
        configMap:
          name: ${JOB}
YAML
rm -f "/tmp/${JOB}.sql"
set +e
kubectl -n "${NS}" wait --for=condition=complete "job/${JOB}" --timeout=90s
WAIT_RC=$?
set -e
kubectl -n "${NS}" logs "job/${JOB}" || true
kubectl -n "${NS}" delete job "${JOB}" --ignore-not-found
kubectl -n "${NS}" delete configmap "${JOB}" --ignore-not-found
exit "${WAIT_RC}"
REMOTE
)"

  echo "[connect] sql job=${job_name} ns=${GATEWAY_NS} file=${SQL_FILE} instance=${INSTANCE_ID}"
  bootstrap_ssm_run "${remote}" 180 "connect-sql"
}

connect_run_shell() {
  if ! command -v session-manager-plugin >/dev/null 2>&1; then
    echo "ERROR: session-manager-plugin is required for interactive SSM sessions." >&2
    echo "Install: https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html" >&2
    echo "Or run: ./scripts/connect.sh help" >&2
    return 1
  fi
  bootstrap_need aws
  bootstrap_need jq
  connect_resolve_host
  bootstrap_wait_ssm
  if [[ -n "${INFRA_DEPLOY_NAME}" ]]; then
    connect_refresh_kubeconfig
  fi
  connect_print_shell_hints
  echo "[connect] starting interactive session (exit to leave)…"
  exec aws ssm start-session --target "${INSTANCE_ID}" --region "${REGION}"
}

connect_main() {
  if ! connect_parse_args "$@"; then
    return 2
  fi
  case "${COMMAND}" in
    help)
      connect_help
      return 0
      ;;
    shell)
      connect_run_shell
      ;;
    env)
      bootstrap_need aws
      connect_resolve_host
      connect_print_env
      ;;
    sql)
      bootstrap_need aws
      connect_resolve_host
      bootstrap_wait_ssm
      connect_run_sql
      ;;
    *)
      echo "ERROR: unknown command ${COMMAND}" >&2
      connect_help
      return 2
      ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  connect_main "$@"
fi
