#!/usr/bin/env bash
# End-to-end read-only checks from the private bootstrap VM.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

usage() {
  cat >&2 <<'EOF'
usage:
  smoke-checks.sh <sandbox|prod> <INFRA_DEPLOY_NAME> <GATEWAY_DEPLOY_NAME> \
    <DOMAIN_NAME> <CLOUDSQL_INSTANCE> <REDIS_INSTANCE>

Optional local environment (sent over IAP stdin and never written):
  SMOKE_API_KEY  Gateway org API key
  SMOKE_MODEL    Registered model-group name

Set both optional values to add an authenticated inference smoke. GPU
provisioning is outside this runbook; the model can point at an existing
provider endpoint.
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi
if [[ $# -ne 6 ]]; then
  usage
  exit 2
fi

ENVIRONMENT_ARG="$1"
INFRA_DEPLOY_NAME="$2"
GATEWAY_DEPLOY_NAME="$3"
DOMAIN_NAME="$4"
CLOUDSQL_INSTANCE="$5"
REDIS_INSTANCE="$6"

bootstrap_assert_dns1123 "${INFRA_DEPLOY_NAME}" "INFRA_DEPLOY_NAME"
bootstrap_assert_dns1123 "${GATEWAY_DEPLOY_NAME}" "GATEWAY_DEPLOY_NAME"
bootstrap_assert_dns1123 "${CLOUDSQL_INSTANCE}" "CLOUDSQL_INSTANCE"
bootstrap_assert_dns1123 "${REDIS_INSTANCE}" "REDIS_INSTANCE"
if [[ ! "${DOMAIN_NAME}" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]] \
  || [[ "${DOMAIN_NAME}" != *.* ]]; then
  printf 'ERROR: DOMAIN_NAME must be a hostname\n' >&2
  exit 2
fi
if [[ -n "${SMOKE_API_KEY:-}" && -z "${SMOKE_MODEL:-}" ]] \
  || [[ -z "${SMOKE_API_KEY:-}" && -n "${SMOKE_MODEL:-}" ]]; then
  printf 'ERROR: set both SMOKE_API_KEY and SMOKE_MODEL, or neither\n' >&2
  exit 2
fi

bootstrap_resolve_targets "${ENVIRONMENT_ARG}"
bootstrap_check_gcloud_auth
bootstrap_wait_vm
bootstrap_print_target

{
  printf 'PROJECT_ID=%q\n' "${PROJECT_ID}"
  printf 'REGION=%q\n' "${REGION}"
  printf 'CLUSTER=%q\n' "${INFRA_DEPLOY_NAME}-gke"
  printf 'NAMESPACE=%q\n' "${GATEWAY_DEPLOY_NAME}"
  printf 'DOMAIN_NAME=%q\n' "${DOMAIN_NAME}"
  printf 'CLOUDSQL_INSTANCE=%q\n' "${CLOUDSQL_INSTANCE}"
  printf 'REDIS_INSTANCE=%q\n' "${REDIS_INSTANCE}"
  printf 'SMOKE_API_KEY=%q\n' "${SMOKE_API_KEY:-}"
  printf 'SMOKE_MODEL=%q\n' "${SMOKE_MODEL:-}"
  cat <<'REMOTE'
set -euo pipefail
PUBLIC_ORIGIN="https://${DOMAIN_NAME}"

echo "[smoke] GKE DNS endpoint and ARM nodes"
gcloud container clusters describe "${CLUSTER}" \
  --project="${PROJECT_ID}" --location="${REGION}" \
  --format=json \
  | jq -e '.status == "RUNNING"
    and .location == "us-east1"
    and .controlPlaneEndpointsConfig.dnsEndpointConfig.allowExternalTraffic == true
    and ((.controlPlaneEndpointsConfig.ipEndpointsConfig.enabled // false) == false)'
gcloud container clusters get-credentials "${CLUSTER}" \
  --project="${PROJECT_ID}" --location="${REGION}" --dns-endpoint
SERVER="$(kubectl config view --minify -o jsonpath="{.clusters[0].cluster.server}")"
case "${SERVER}" in
  https://*.gke.goog) ;;
  *) echo "ERROR: kubeconfig is not using the IAM-protected DNS endpoint" >&2; exit 1 ;;
esac
kubectl wait --for=condition=Ready nodes --all --timeout=10m
kubectl get nodes -o json | jq -e '
  (.items | length >= 2)
  and all(.items[];
    .status.nodeInfo.architecture == "arm64"
    and .metadata.labels["node.kubernetes.io/instance-type"] == "n4a-standard-4")'

echo "[smoke] Cloud SQL PostgreSQL 16 regional HA/private IP/PITR"
gcloud sql instances describe "${CLOUDSQL_INSTANCE}" \
  --project="${PROJECT_ID}" --format=json \
  | jq -e '
    .state == "RUNNABLE"
    and .databaseVersion == "POSTGRES_16"
    and .region == "us-east1"
    and .settings.availabilityType == "REGIONAL"
    and ((.settings.ipConfiguration.ipv4Enabled // false) == false)
    and (.settings.ipConfiguration.privateNetwork | length > 0)
    and .settings.ipConfiguration.sslMode == "ENCRYPTED_ONLY"
    and .settings.backupConfiguration.enabled == true
    and .settings.backupConfiguration.pointInTimeRecoveryEnabled == true
    and .settings.deletionProtectionEnabled == true'

echo "[smoke] Memorystore Redis 7 Standard HA with AUTH and TLS"
gcloud redis instances describe "${REDIS_INSTANCE}" \
  --project="${PROJECT_ID}" --region="${REGION}" --format=json \
  | jq -e '
    .state == "READY"
    and .tier == "STANDARD_HA"
    and (.redisVersion | startswith("REDIS_7"))
    and .authEnabled == true
    and .transitEncryptionMode == "SERVER_AUTHENTICATION"'

echo "[smoke] ESO and fixed cluster secrets"
kubectl get clustersecretstore orangeline-gcp-secretmanager -o json \
  | jq -e 'any(.status.conditions[]?;
      .type == "Ready" and .status == "True")'
kubectl -n "${NAMESPACE}" get externalsecrets.external-secrets.io -o json \
  | jq -e '(.items | length > 0) and all(.items[];
      any(.status.conditions[]?; .type == "Ready" and .status == "True"))'
for secret in gateway-secrets router-secrets worker-secrets; do
  kubectl -n "${NAMESPACE}" get secret "${secret}" >/dev/null
done
kubectl -n "${NAMESPACE}" get secret gateway-secrets -o json \
  | jq -e '.data.SUBCONSCIOUS_GATEWAY_REDIS_CA_CERT | length > 0'

echo "[smoke] gateway and Distr rollouts"
kubectl -n "${NAMESPACE}" rollout status deployment/distr-agent --timeout=5m
kubectl -n "${NAMESPACE}" get deployment -o json \
  | jq -e '(.items | length > 1) and all(.items[];
      (.status.availableReplicas // 0) >= (.spec.replicas // 1))'

echo "[smoke] GCE Ingress resources"
kubectl -n "${NAMESPACE}" get managedcertificates.networking.gke.io -o json \
  | jq -e '(.items | length > 0)
      and all(.items[]; .status.certificateStatus == "Active")'
kubectl -n "${NAMESPACE}" get frontendconfigs.networking.gke.io -o json \
  | jq -e '(.items | length > 0)
      and all(.items[]; .spec.redirectToHttps.enabled == true)'
kubectl -n "${NAMESPACE}" get backendconfigs.cloud.google.com -o json \
  | jq -e '(.items | length > 0)
      and all(.items[]; .spec.timeoutSec == 900)'
INGRESS_JSON="$(kubectl -n "${NAMESPACE}" get ingress -o json)"
STATIC_IP_NAME="$(jq -er '.items[0].metadata.annotations["kubernetes.io/ingress.global-static-ip-name"]' <<<"${INGRESS_JSON}")"
jq -e '.items[0].metadata.annotations["networking.gke.io/managed-certificates"] | length > 0' \
  <<<"${INGRESS_JSON}" >/dev/null
gcloud compute addresses describe "${STATIC_IP_NAME}" \
  --project="${PROJECT_ID}" --global --format='value(status)' \
  | grep -Fxq "IN_USE"

echo "[smoke] Datadog Agent"
kubectl -n datadog get daemonset -o json \
  | jq -e '(.items | length > 0) and any(.items[];
      (.status.numberReady // 0) == (.status.desiredNumberScheduled // -1)
      and (.status.desiredNumberScheduled // 0) > 0)'

echo "[smoke] public redirect and readiness"
HTTP_CODE="$(curl --connect-timeout 10 --max-time 30 -sS -o /dev/null \
  -w "%{http_code}" "http://${DOMAIN_NAME}/")"
case "${HTTP_CODE}" in
  301|302|307|308) ;;
  *) echo "ERROR: HTTP did not redirect to HTTPS (status ${HTTP_CODE})" >&2; exit 1 ;;
esac
curl --connect-timeout 10 --max-time 60 -fsS "${PUBLIC_ORIGIN}/healthz" >/dev/null
curl --connect-timeout 10 --max-time 60 -fsS "${PUBLIC_ORIGIN}/readyz" >/dev/null
curl --connect-timeout 10 --max-time 60 -fsS "${PUBLIC_ORIGIN}/dashboard/login" >/dev/null

if [[ -n "${SMOKE_API_KEY}" ]]; then
  echo "[smoke] authenticated inference"
  curl --connect-timeout 10 --max-time 900 -fsS \
    "${PUBLIC_ORIGIN}/v1/chat/completions" \
    -H "Authorization: Bearer ${SMOKE_API_KEY}" \
    -H "Content-Type: application/json" \
    --data "$(jq -nc --arg model "${SMOKE_MODEL}" \
      '{model:$model,messages:[{role:"user",content:"Reply with OK"}],stream:false}')" \
    | jq -e '.choices[0].message.content | length > 0' >/dev/null
fi

echo "[smoke] OK"
REMOTE
} | bootstrap_ssh \
  --command='sudo env HOME=/root KUBECONFIG=/root/.kube/config USE_GKE_GCLOUD_AUTH_PLUGIN=True bash -s'
