# Troubleshooting (GCP API Gateway)

Common failure modes for the greenfield GCP deployment.

Architecture: [README.md](README.md) · Setup:
[instructions.md](instructions.md) · Secrets:
[gateway-secrets.md](gateway-secrets.md) · Rollback:
[rollback.md](rollback.md) · Teardown:
[teardown.md](teardown.md).

Do not troubleshoot by adding a public VM IP, enabling a GKE IP endpoint,
creating a service-account key, disabling Redis AUTH/TLS, enabling Cloud SQL
public IP, or pasting a secret into Helm.

## Release and Distr

### Runner says GCP is not implemented/stubbed

The selected `api-gateway-infra` release does not support this runbook. That is
a release-gate failure, not an IAM or environment problem.

Stop the deployment and select only a release whose notes explicitly implement
the complete GCP contract. Do not patch around the stub from the bootstrap VM.

### `entitlement required` or image pull denied

Deployment targets do not grant artifact access. The customer organization
needs both Application and artifact entitlements for the exact runner, chart,
gateway, router, adapter, migration, and helper image tags.

Confirm ARM64 manifests exist:

```bash
sudo docker manifest inspect <ENTITLED_IMAGE>
```

Do not paste registry credentials into Docker configuration manually; reconnect
the Distr target after entitlement correction.

### First/second deploy confusion

Required order:

1. first infra apply with `GATEWAY_AUTO_DEPLOY=false`;
2. create Helm deployment/target;
3. connect K8s agent through the DNS endpoint;
4. second infra apply with auto-deploy enabled.

An empty gateway deployment before the Kubernetes target exists is expected to
do nothing. Auto-deploy looks up the Hub target named
`GATEWAY_DISTR_PORTAL_NAME` (defaults to `GATEWAY_DISTR_DEPLOYMENT_NAME`).
After a Hub-only rename, set `GATEWAY_DISTR_PORTAL_NAME` rather than changing
the cluster identity. Logs: `no Distr deployment target named …`.
Hand-edited Hub Helm values will be overwritten by the next runner fragment.

### Terraform plan-only run

As on AWS, `DISTR_DRY_RUN=1` shows the Terraform plan and stops. Return it to
`0` and trigger the infra deployment to apply. A normal new installation uses
`0`; plan-only is an optional operator review tool, not another required
deployment stage.

## Foundation projects and APIs

### Existing project or billing access denied

The human foundation identity must be able to read the selected existing
project and its attached billing account, enable required services, administer
the documented IAM bindings, and create the foundation resources. Confirm the
project is ACTIVE and billing is enabled.

```bash
gcloud billing accounts get-iam-policy <BILLING_ACCOUNT_ID>
gcloud projects get-iam-policy <PROJECT_ID>
```

Do not grant the VM service account billing-account access.

### API not enabled / Service Usage 403

Run:

```bash
cd api-gateway/gcp/bootstrap
bash scripts/preflight.sh
```

The bootstrap Terraform enables required APIs. Fix the human/organization
policy or rerun `scripts/bootstrap.sh`. Do not enable random APIs until
the missing service name is identified.

### Terraform backend access denied

Check the environment-specific bucket and attached platform service account:

```bash
gcloud storage buckets describe "gs://$TF_STATE_BUCKET"
gcloud storage buckets get-iam-policy "gs://$TF_STATE_BUCKET"
```

The VM service account receives Storage Admin only on the production state
bucket. Do not copy state locally to bypass IAM.

## Bootstrap VM, IAP, and Docker

### IAP SSH fails

The human needs:

- `roles/iap.tunnelResourceAccessor` on the project;
- `roles/compute.osAdminLogin` (or OS Login) on the project;
- `roles/compute.viewer` for instance discovery;
- `roles/iam.serviceAccountUser` on the attached VM service account.

The VPC firewall must allow TCP/22 from `35.235.240.0/20` to the VM service
account. Verify:

```bash
gcloud compute firewall-rules describe gateway-allow-iap-ssh \
  --project="$GCP_PROJECT"
gcloud compute instances describe gateway-bootstrap \
  --project="$GCP_PROJECT" --zone="$GCP_ZONE" \
  --format='yaml(status,networkInterfaces,metadata,serviceAccounts)'
```

If the user belongs to a different Google Workspace organization, an org admin
may also need `roles/compute.osLoginExternalUser`.

### VM has no egress / package or registry pulls fail

No public IP is expected. Check Cloud NAT, router, subnet, Private Google
Access, DNS, and NAT logs:

```bash
gcloud compute routers nats describe gateway-bootstrap \
  --router=gateway-bootstrap \
  --region=us-east1 \
  --project="$GCP_PROJECT"
```

Repair host packages after egress is fixed:

```bash
bash api-gateway/gcp/bootstrap/scripts/repair-host.sh
```

Do not add an `access_config` to the VM.

### Docker agent unhealthy

Open the VM:

```bash
bash api-gateway/gcp/bootstrap/scripts/connect.sh
sudo -i
docker ps -a
docker logs --tail 200 <distr-agent-container>
docker logs --tail 200 <runner-container>
cat /opt/api-gateway-infra/status
```

Common causes are entitlement failure, wrong connect target, stubbed runner,
missing Hub fields, Datadog API errors, or Terraform plan/apply failure.
Reconnect the target if the one-time URL was exposed.

## GKE DNS control-plane access

### `get-credentials --dns-endpoint` denied

Separate two layers:

1. IAM/GFE access needs `container.clusters.connect` (included in appropriate
   GKE Viewer/Developer/Admin roles).
2. Kubernetes operations need IAM-to-RBAC authorization for the principal.

From the VM:

```bash
gcloud auth list
gcloud container clusters describe "$CLUSTER" \
  --project="$GCP_PROJECT" --location=us-east1 \
  --format='yaml(status,controlPlaneEndpointsConfig)'
gcloud container clusters get-credentials "$CLUSTER" \
  --project="$GCP_PROJECT" --location=us-east1 --dns-endpoint
kubectl auth can-i get namespaces
```

The kubeconfig server must end in `.gke.goog`. If DNS access is disabled or IP
endpoints are enabled contrary to the contract, fix the reviewed infra release;
do not use `--internal-ip` as a permanent bypass.

### DNS endpoint works but `kubectl` is forbidden

IAM authenticated the connection, but Kubernetes authorization rejected the
operation. Review the GKE IAM role and the release-managed RBAC/Access binding
for the bootstrap VM service account. Grant only the cluster administration
required by the runner; do not use an anonymous/admin certificate.

### N4A nodes do not create or pods show `exec format error`

Check quota, capacity, zones, node service account, image manifests, and
selectors:

```bash
gcloud compute machine-types describe n4a-standard-4 \
  --project="$GCP_PROJECT" --zone=<US_EAST1_ZONE>
kubectl get nodes -L node.kubernetes.io/instance-type,kubernetes.io/arch
kubectl describe pod -n "$NAMESPACE" <POD>
```

Every gateway node must be `n4a-standard-4`/`arm64`. Do not silently change to
x86/T2A. Escalate capacity and reschedule the deployment if the locked shape is
unavailable.

## Secret Manager, WIF, and ESO

### ClusterSecretStore or ExternalSecret not Ready

```bash
kubectl describe clustersecretstore orangeline-gcp-secretmanager
kubectl -n "$NAMESPACE" describe externalsecret
kubectl -n external-secrets logs deploy/external-secrets --tail=200
```

Check:

- GKE WIF enabled;
- correct project ID in the store;
- KSA annotation/direct principal;
- `roles/iam.workloadIdentityUser` binding when using a GCP service account;
- `roles/secretmanager.secretAccessor` on exactly the environment secrets;
- enabled secret versions.

Do not print payloads or create a JSON key. See
[gateway-secrets.md](gateway-secrets.md).

### `gateway-secrets` exists but readiness fails

Check ExternalSecret condition/revision and pod events, not secret data. Likely
causes are malformed URL encoding, Cloud SQL private routing/TLS, Redis
CA/TLS/AUTH, or a stale version. Correct through the infra runner so Secret
Manager remains the source of truth.

## Cloud SQL PostgreSQL

### Private connection timeout

Verify:

- Cloud SQL `ipv4Enabled=false`;
- private network references the platform VPC;
- Service Networking peering/range is active and non-overlapping;
- GKE Pod egress/NetworkPolicy permits the private address/port 5432;
- connection URL requires encrypted transport.

```bash
gcloud sql instances describe "$CLOUDSQL_INSTANCE" \
  --project="$GCP_PROJECT" \
  --format='yaml(state,region,databaseVersion,settings.availabilityType,settings.ipConfiguration,ipAddresses)'

gcloud services vpc-peerings list \
  --project="$GCP_PROJECT" \
  --network="$VPC_NETWORK"
```

Do not enable public IP as a diagnostic shortcut.

### DBM cannot connect

Cloud Monitoring metrics through STS can be healthy while direct DBM fails.
Check the Datadog namespace Secret/ESO, private route, TLS trust,
`pg_stat_statements`, DBM user grants, and Agent cluster-check assignment. See
[datadog-operations.md](datadog-operations.md).

## Memorystore Redis

### TLS handshake or AUTH failure

```bash
gcloud redis instances describe "$REDIS_INSTANCE" \
  --project="$GCP_PROJECT" --region=us-east1 \
  --format='yaml(state,tier,redisVersion,host,port,authEnabled,transitEncryptionMode,serverCaCerts)'
```

Required: `READY`, `STANDARD_HA`, Redis 7, `authEnabled: true`,
`SERVER_AUTHENTICATION`, and TLS port (normally 6378). Verify the application
image trusts the returned server CA and the URL is safely encoded.

Do not disable TLS/peer verification or expose the AUTH string. Redis AUTH
rotation is disruptive; use the blue/green procedure in
[secret-rotation.md](secret-rotation.md).

## GCE Ingress, DNS, and certificate

### Ingress has no address/backend unhealthy

```bash
kubectl -n "$NAMESPACE" describe ingress
kubectl -n "$NAMESPACE" get ingress,svc,endpoints
kubectl -n "$NAMESPACE" get events --sort-by=.lastTimestamp
gcloud compute addresses describe "$STATIC_IP_NAME" \
  --project="$GCP_PROJECT" --global
```

Check the `gce` class annotation, reserved global IP annotation, NEG/backend
health, Service type/ports, readiness probe path, firewall permissions, and GKE
service agent.

### ManagedCertificate stays Provisioning/FailedNotVisible

```bash
kubectl -n "$NAMESPACE" describe managedcertificate
dig +short "$DOMAIN_NAME"
gcloud compute addresses describe "$STATIC_IP_NAME" \
  --project="$GCP_PROJECT" --global --format='value(address)'
```

DNS must resolve publicly to the reserved IP and the zone must be delegated.
Certificate activation can take tens of minutes after correct visibility.
Avoid repeatedly deleting/recreating it; that restarts provisioning and can hit
quota.

### HTTP does not redirect

Confirm the Ingress references the FrontendConfig and:

```bash
kubectl -n "$NAMESPACE" get frontendconfig -o yaml
curl -sS -o /dev/null -D - "http://$DOMAIN_NAME/"
```

`redirectToHttps.enabled` must be true. Do not implement an application-only
redirect as a substitute.

### Streaming request ends near 30 seconds

The Service must reference a BackendConfig with `timeoutSec: 900`:

```bash
kubectl -n "$NAMESPACE" get backendconfig -o json \
  | jq '.items[] | {name:.metadata.name,timeoutSec:.spec.timeoutSec}'
kubectl -n "$NAMESPACE" get service -o yaml
```

Fix the generated GCP Helm fragment/Service annotation and redeploy through
infra. Do not hand-edit the live BackendConfig; auto-deploy will overwrite it.

## Datadog

### Datadog delegate is not in the permitted organization

`constraints/iam.allowedPolicyMemberDomains` is blocking Datadog's external
STS delegate. Do not disable Domain Restricted Sharing globally. Have an
organization policy administrator add Datadog customer identity `C0147pk0i`
(`C03lf3ewa` for government sites) to a project-level override while retaining
the existing corporate customer identity. See
[datadog-operations.md](datadog-operations.md#domain-restricted-sharing-prerequisite).

### No GCP metrics but Agent data exists

The Agent and STS integration are independent. Check the Datadog integration
account, delegate impersonation binding, project filters, and Monitoring/Asset/
Compute/Cloud SQL Viewer roles. Ensure the delegate belongs to the intended
Datadog organization.

### Agent missing on nodes

Check ARM64 image support, entitlements, taints, resources, and DaemonSet
events. Do not use an amd64-only override on N4A.

More: [datadog-operations.md](datadog-operations.md).

## Release rollback

Prefer fix-forward. Do not run direct `helm rollback`; Distr must remain the
desired-state owner. The database schema is never reverted (migrations are
additive and forward-compatible); gateway version rollback is in
[rollback.md](rollback.md). Ordered teardown is in [teardown.md](teardown.md).
