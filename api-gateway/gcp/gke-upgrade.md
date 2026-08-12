# Staged GKE minor upgrade

Upgrade one Kubernetes minor version at a time with a version-specific,
vendor-qualified `api-gateway-infra` release. This document does not authorize
a specific future version. The target must appear in the release notes and be
available in `us-east1` on the cluster's release channel.

GKE control-plane upgrades are effectively forward-only for this procedure.
Do not assume that a control-plane downgrade is available. The primary risk
controls are compatibility checks, saved-plan review, backups, surge capacity,
separate application rollout, and fix-forward ownership.

## Scope

The infra upgrade can change:

- regional GKE control-plane version;
- N4A node-pool version/image and surge settings;
- pinned cluster add-ons/controllers, ESO, Datadog Agent, and cleanup tools.

It must not combine:

- a gateway Application version change;
- Cloud SQL/Redis topology or credential rotation;
- DNS/ingress redesign;
- project/IAM restructuring;
- GPU/worker changes.

Set `GATEWAY_AUTO_DEPLOY=false` and
`GATEWAY_CHART_VERSION=nochange` for the entire GKE operation.

## Required inputs and access

Record:

```bash
export GCP_PROJECT='<PRODUCTION_PROJECT>'
export GCP_REGION='us-east1'
export CLUSTER='<INFRA_DEPLOY_NAME>'
export NAMESPACE='<GATEWAY_DEPLOY_NAME>'
export PUBLIC_ORIGIN='https://<DOMAIN_NAME>'
```

Open the private bootstrap VM:

```bash
cd api-gateway/gcp/bootstrap
bash scripts/connect.sh "$CLUSTER"
sudo -i
export HOME=/root KUBECONFIG=/root/.kube/config
export USE_GKE_GCLOUD_AUTH_PLUGIN=True
```

The kubeconfig server must end in `.gke.goog`; IP endpoint access remains
disabled during and after the upgrade.

## Change preparation

- [ ] Exact current and target versions recorded; target is exactly one minor
  ahead.
- [ ] Google GKE version availability/end-of-support and release-channel timing
  checked live.
- [ ] Vendor-designated infra release and provider lock selected (not `latest`).
- [ ] Gateway compatibility release deployed and soaked separately on the
  current GKE version, then frozen.
- [ ] Vendor qualification evidence and release-specific upgrade notes reviewed.
- [ ] Saved Terraform plan changes only the approved GKE upgrade resources.
- [ ] N4A quota has at least one surge node per zone (or the released strategy's
  documented capacity).
- [ ] PodDisruptionBudgets, topology spread, readiness probes, and two replicas
  verified.
- [ ] Cloud SQL backup/PITR and current backup completion verified.
- [ ] No active Datadog alert or unrelated change.
- [ ] Fix-forward and incident owners staffed for the maintenance window and
  24-hour soak.

## Pre-upgrade gates

Run from the bootstrap VM:

```bash
gcloud container clusters describe "$CLUSTER" \
  --project="$GCP_PROJECT" \
  --location="$GCP_REGION" \
  --format='yaml(status,currentMasterVersion,currentNodeVersion,releaseChannel,controlPlaneEndpointsConfig)'

gcloud container get-server-config \
  --project="$GCP_PROJECT" \
  --region="$GCP_REGION"

kubectl wait --for=condition=Ready nodes --all --timeout=10m
kubectl get nodes -o json | jq -e '
  (.items | length >= 2)
  and all(.items[];
    .status.nodeInfo.architecture == "arm64"
    and .metadata.labels["node.kubernetes.io/instance-type"] == "n4a-standard-4")'

kubectl -n "$NAMESPACE" get pdb,deploy,pods
kubectl -n "$NAMESPACE" rollout status deployment/distr-agent --timeout=5m
kubectl get clustersecretstore orangeline-gcp-secretmanager
kubectl -n "$NAMESPACE" get externalsecret

curl -fsS "$PUBLIC_ORIGIN/healthz"
curl -fsS "$PUBLIC_ORIGIN/readyz"
curl -fsS "$PUBLIC_ORIGIN/dashboard/login" >/dev/null
```

Review GKE deprecation/upgrade insights and release notes for removed APIs. Save:

```bash
kubectl get --raw /metrics | grep apiserver_requested_deprecated_apis || true
kubectl api-resources
kubectl get events -A --sort-by=.lastTimestamp
```

Also run [bootstrap/scripts/smoke-checks.sh](bootstrap/scripts/smoke-checks.sh)
with the environment's managed-service names. Any failed gate, pending
certificate, unsynced secret, unavailable node, active provider incident, or
unexplained alert is a stop.

## Dry-run

In the existing infra Docker deployment:

1. Select the exact vendor-designated one-minor upgrade release.
2. Preserve all environment-specific values and secret references.
3. Set:

   ```text
   GKE_VERSION=<EXACT_TARGET_MINOR_OR_FULL_GKE_VERSION>
   GATEWAY_AUTO_DEPLOY=false
   GATEWAY_CHART_VERSION=nochange
   DISTR_DRY_RUN=1
   ```

4. Save the full runner log and Terraform plan.

Expected changes are limited to the GKE control plane, N4A node pool, and
explicitly release-pinned cluster components. Reject:

- project/VPC/subnet/range replacement;
- Cloud SQL, Redis, GCS state, static IP, DNS, or Secret Manager replacement;
- enabling an IP control-plane endpoint;
- changing node architecture/machine type;
- selecting a gateway Application version;
- more than one minor-version step.

The runner idles after plan-only. Stop/replace that revision after collecting
evidence.

## Apply

After approval, change only:

```text
DISTR_DRY_RUN=0
```

Run one infra deployment. Do not start concurrent Terraform or `gcloud
container clusters upgrade` commands. Follow GKE operations and Distr logs.

The released Terraform should:

1. verify controllers/secrets before disruption;
2. upgrade the regional control plane;
3. roll the node pool with approved surge/unavailable settings;
4. verify DNS-endpoint access, nodes, add-ons, ESO, Datadog, and workloads.

Do not manually remove old nodes while a managed operation is active.

## Immediate post-upgrade gates

```bash
gcloud container clusters describe "$CLUSTER" \
  --project="$GCP_PROJECT" \
  --location="$GCP_REGION" \
  --format='yaml(status,currentMasterVersion,currentNodeVersion,releaseChannel,controlPlaneEndpointsConfig)'

gcloud container operations list \
  --project="$GCP_PROJECT" \
  --location="$GCP_REGION" \
  --filter="targetLink~${CLUSTER}" \
  --sort-by='~startTime'

kubectl wait --for=condition=Ready nodes --all --timeout=15m
kubectl get nodes \
  -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.nodeInfo.kubeletVersion}{" "}{.status.nodeInfo.architecture}{" "}{.metadata.labels.node\.kubernetes\.io/instance-type}{"\n"}{end}'

kubectl get pods -A -o json | jq -e '
  all(.items[];
    .status.phase == "Running"
    or .status.phase == "Succeeded"
    or .metadata.ownerReferences[0].kind == "Job")'

kubectl get clustersecretstore orangeline-gcp-secretmanager
kubectl -n "$NAMESPACE" get externalsecret
kubectl -n "$NAMESPACE" rollout status deployment/distr-agent --timeout=5m
```

Repeat every pre-upgrade HTTP, application, managed-service, ingress,
certificate, ESO, and Datadog gate. Confirm:

- all nodes use the exact target minor, ARM64, and `n4a-standard-4`;
- DNS endpoint still used and IP endpoints disabled;
- Cloud SQL/Redis configuration unchanged;
- ManagedCertificate Active, static IP unchanged, redirect works, backend
  timeout remains 900 seconds;
- no new error-rate, latency, database, Redis, NAT, or node alert.

## 24-hour soak

For 24 continuous hours:

- hold infra/gateway versions and configuration unchanged;
- run readiness and an authenticated request at start, one hour, and end;
- monitor restarts, scheduling, GKE operations, Datadog, Cloud SQL, Redis,
  ingress, certificate, NAT, ESO, and both Distr agents;
- keep the old release metadata and incident owner available.

A successful soak does not authorize the next minor upgrade.

## Partial failure and recovery

- **Before a GKE operation starts:** correct the prerequisite or revert the
  desired target/release and rerun the dry-run.
- **Control plane upgraded, node pool pending/failed:** do not attempt a
  control-plane downgrade. Preserve state, resolve quota/PDB/image/capacity,
  and rerun the same pinned infra release.
- **Some nodes upgraded:** let the managed operation settle; fix quota,
  disruption budget, or workload compatibility, then resume through the same
  Terraform release.
- **Application regression:** keep the cluster at the target version and
  fix-forward the compatible gateway/controller release. Use Distr desired
  versions, not direct Helm rollback.
- **Node image regression:** use only a Google/vendor-supported node-pool
  rollback or a separately managed replacement pool compatible with the
  upgraded control plane. Do not improvise an older unsupported kubelet.

Never restore old Terraform state over upgraded infrastructure, delete/recreate
the regional cluster during incident response, enable a public IP endpoint, or
combine recovery with database/secret rotation.
