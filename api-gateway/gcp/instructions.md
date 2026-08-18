# GCP API Gateway setup instructions

End-to-end greenfield deployment for a production-parity sandbox followed by
production. Roles are labeled **FDE** (Subconscious Forward Deployed Engineer)
and **Admin** (customer cloud/platform administrator).

Architecture: [README.md](README.md). Bootstrap: [bootstrap/](bootstrap/).
Secrets: [gateway-secrets.md](gateway-secrets.md). Datadog:
[datadog-operations.md](datadog-operations.md). Troubleshooting:
[troubleshooting.md](troubleshooting.md).

## Non-negotiable stop conditions

Stop before cloud creation if any of these is false:

- The selected `api-gateway-infra` Application release explicitly supports a
  complete `CLOUD=gcp` deployment. A stubbed GCP runner is not usable.
- Sandbox and production project IDs are different.
- Region is `us-east1`, and N4A quota/capacity is confirmed in at least two
  zones.
- GKE IP endpoints will be disabled and the IAM-protected DNS endpoint enabled.
- The bootstrap VM will have no public IP and no service-account key.
- Cloud SQL and Redis can use private service access in the planned CIDRs.
- DNS delegation and a unique hostname are approved for each environment.
- Current live cloud and Datadog pricing has been reviewed.

Do not use this procedure to migrate an AWS database/cache, copy AWS Terraform
state, or provision GPU hosts.

## 1. FDE: verify release and entitlements

In the Distr Vendor portal:

- [ ] Customer organization exists.
- [ ] Application entitlements include `api-gateway-infra` (Docker) and
  `api-gateway` (Helm).
- [ ] Artifact entitlements include the runner, chart, gateway/router/adapter,
  migration, cleanup, and Datadog helper images for the approved release.
- [ ] The exact infra release notes list all items in
  [README.md#required-release-contract](README.md#required-release-contract).
- [ ] The exact gateway release supports ARM64 and the GCE
  Ingress/ManagedCertificate/FrontendConfig/BackendConfig overlay.
- [ ] Both releases completed a greenfield sandbox dress rehearsal.

Pin exact versions for production. `latest` is acceptable only for the first
disposable sandbox trial and must be resolved/recorded before promotion.

## 2. Admin: choose the two environment identities

Keep deployment names at most 32 characters.

| Item | Sandbox example | Production example |
| --- | --- | --- |
| GCP project | `acme-gateway-sbox` | `acme-gateway-prod` |
| Infra Distr / GKE cluster | `acme-sbox-gw-infra` | `acme-prod-gw-infra` |
| Gateway Distr / namespace / release | `acme-sbox-gateway` | `acme-prod-gateway` |
| Cloud DNS managed zone | `acme-gw-sbox` | `acme-gw-prod` |
| Hostname | `api.sbox.example.com` | `api.example.com` |
| Datadog env | `acme-gateway-sbox` | `acme-gateway-prod` |

Record one canonical, non-overlapping RFC1918 `/16` per environment:

```text
sandbox bootstrap subnet  10.40.0.0/24
sandbox platform VPC      10.60.0.0/16
production bootstrap      10.41.0.0/24
production platform VPC   10.70.0.0/16
```

The platform derives fixed node, Pod, Service, private-service-access, and
control-plane ranges from `VPC_CIDR`. Do not supply or hand-edit separate
derived ranges. Ensure the `/16` does not overlap the bootstrap subnet, the
other environment, or any network that may later be connected.

## 3. Admin: install local tools and authenticate

```bash
git clone git@github.com:subconscious-systems/ol-runbook.git
cd ol-runbook/api-gateway/gcp/bootstrap

bash scripts/install-gcloud.sh
bash scripts/setup-gcloud.sh --quota-project <EXISTING_ADMIN_PROJECT>
terraform version
gcloud auth list
gcloud auth application-default print-access-token >/dev/null
```

Use human user/ADC login. Do not run `gcloud auth activate-service-account
--key-file`, create a JSON key, or copy ADC into the repository.

## 4. Admin: authorize the foundation apply

The day-0 human needs project creation on the selected folder/organization,
billing-account user, and permission to enable services/set IAM in the new
projects. See [bootstrap/README.md](bootstrap/README.md) for the exact split.

Confirm the billing account is open and the intended parent is correct:

```bash
gcloud billing accounts list
gcloud resource-manager folders describe <FOLDER_ID>
# or:
gcloud organizations describe <ORGANIZATION_ID>
```

An organization policy may block external IPs, service-account keys, or public
load balancers. The first two are compatible with this runbook. A policy that
blocks the public GCE HTTPS load balancer must be resolved by security before
deployment; do not weaken it ad hoc.

## 5. Admin: create only the sandbox project and bootstrap VM

```bash
cd api-gateway/gcp/bootstrap
cp terraform.tfvars.example terraform.tfvars
$EDITOR terraform.tfvars

bash scripts/bootstrap.sh --plan
# Review: enabled_environments contains only sandbox; one project, budget,
# state bucket, isolated bootstrap VPC/NAT, keyless service account/IAM, IAP
# firewall, and one private VM.
bash scripts/bootstrap.sh --apply
```

The apply is intentionally not auto-approved. Confirm:

- no `access_config`/public VM IP;
- no service-account key resource;
- no Owner or Editor grant to the VM service accounts;
- project and VM deletion protection remain enabled;
- no production project, budget, network, state bucket, or VM is in the plan.

## 6. Admin: migrate bootstrap state to GCS

The first apply uses local state because it creates its own backend buckets.

```bash
bash scripts/migrate-state.sh
terraform state list
terraform plan
```

The post-migration plan must be empty. Securely retain the automatic local state
backup until the remote state can be read by a second authorized operator.
Never commit state, `terraform.tfvars`, `backend.tf`, `.backend.hcl`, plans, or
credentials.

## 7. Admin: verify APIs, billing, IAM, and host posture

```bash
bash scripts/preflight.sh sandbox
# Run `bash scripts/preflight.sh prod` only after the approved production
# foundation has been added.
```

Also review the long-lived platform-applier service account:

```bash
gcloud projects get-iam-policy <PROJECT_ID> \
  --flatten='bindings[].members' \
  --filter='bindings.members:gateway-ENV-platform@' \
  --format='table(bindings.role,bindings.members)'

gcloud iam service-accounts keys list \
  --iam-account gateway-ENV-platform@<PROJECT_ID>.iam.gserviceaccount.com
```

Only Google-managed keys should exist. The role set is documented in
[bootstrap/README.md#long-lived-vm-service-account-roles](bootstrap/README.md#long-lived-vm-service-account-roles).
After this gate, remove temporary project-creator/billing grants from the human
if your change process requires it; retain IAP/OS Login for the operator group.

## 8. Admin: confirm quota and regional product availability

Perform this for sandbox now and repeat it for production only after the
production foundation gate. At minimum review:

- Compute Engine N4A CPU quota and `n4a-standard-4` availability in two
  `us-east1` zones;
- regional GKE clusters/nodes and SSD quota;
- Cloud SQL regional HA CPUs/storage/backups;
- Memorystore capacity and private service access;
- VPC peering/ranges, Cloud NAT, global static IP, forwarding rules, health
  checks, and SSL certificate quota.

Do not silently substitute T2A, C4A, x86, zonal SQL, Basic Redis, or a public
cluster endpoint. Any topology change needs a revised design and cost review.

## 9. Admin: create/delegate Cloud DNS zones

Create or use a public managed zone in each environment project. If the
corporate parent zone lives elsewhere, delegate a distinct subzone and grant
the environment platform service account DNS administration only on the
approved DNS project/zone.

Example for a delegated production zone:

```bash
gcloud dns managed-zones create acme-gw-prod \
  --project=acme-gateway-prod \
  --dns-name=gateway.example.com. \
  --description='Production Subconscious gateway'

gcloud dns managed-zones describe acme-gw-prod \
  --project=acme-gateway-prod \
  --format='value(nameServers)'
```

Publish the returned NS records in the parent zone and verify delegation before
the gateway deploy. Set `DNS_ZONE_NAME` to the **managed-zone resource name**,
not the DNS suffix. Use a unique `DOMAIN_NAME` below that zone.

When the zone is in a separate DNS project, its DNS API must already be
enabled. Grant each environment's attached platform service account record-set
administration in that DNS project through the customer's normal IAM change
process:

```bash
gcloud projects add-iam-policy-binding <DNS_PROJECT_ID> \
  --member="serviceAccount:gateway-sandbox-platform@<SANDBOX_PROJECT_ID>.iam.gserviceaccount.com" \
  --role=roles/dns.admin
gcloud projects add-iam-policy-binding <DNS_PROJECT_ID> \
  --member="serviceAccount:gateway-prod-platform@<PRODUCTION_PROJECT_ID>.iam.gserviceaccount.com" \
  --role=roles/dns.admin
```

Use a narrower custom role if available. Platform Terraform intentionally does
not enable APIs or modify IAM in the separate DNS project.

## 10. Admin: create Distr Hub Secrets

Create masked secrets separately for sandbox and production:

| Hub secret | Purpose |
| --- | --- |
| `{env}_DISTR_TOKEN` | Customer PAT used by that infra runner |
| `{env}_DD_API_KEY` | Datadog provider/Agent |
| `{env}_DD_APP_KEY` | Datadog managed assets and GCP STS integration |
| `{gw}_GATEWAY_DASHBOARD_BOOTSTRAP_PASSWORD` | Optional first admin, at least 12 characters |
| `{gw}_GATEWAY_DASHBOARD_OIDC_CLIENT_SECRET` | Optional OIDC secret |

Do not add a GCP credential JSON, database URL, Redis URL/AUTH string, CSRF
secret, encryption key, or worker key to Hub. See
[gateway-secrets.md](gateway-secrets.md).

## 11. Admin: create the sandbox infra Docker deployment

Create an `api-gateway-infra` Docker deployment/target named with the sandbox
infra name. Start from [sample-gateway-infra.env](sample-gateway-infra.env):

- set `GCP_PROJECT` to the sandbox project;
- use the sandbox hostname, managed zone, CIDRs, names, state bucket, and
  Datadog env;
- keep all locked GCP topology/security values unchanged;
- set `GATEWAY_AUTO_DEPLOY=false`;
- leave `GATEWAY_LOG_LEVEL=WARN` (one field for gateway, adapter, and router);
- leave `DATADOG_APM_ENABLED` and `DATADOG_LLM_OBS_ENABLED` false;
- set `DISTR_DRY_RUN=1`;
- use Hub secret references, never plaintext.

Compare the sample with the selected release's own environment template. Every
required field must be recognized by that release; unknown fields or a stub
message are a hard stop.

## 12. Admin: connect the sandbox Docker agent

Copy only the one-time Docker target connect URL:

```bash
cd api-gateway/gcp/bootstrap
bash scripts/run-agent.sh sandbox \
  'https://app.distr.sh/api/v1/connect?targetId=...&targetSecret=...'
```

The URL is sent over IAP stdin to the private VM. Reconnect in Hub if it is
exposed. Wait for the Docker target and runner container to be healthy.

## 13. FDE + Admin: review the sandbox infra dry-run

Trigger the infra deployment with `DISTR_DRY_RUN=1`. The plan must create:

- custom platform VPC/subnets/ranges, Cloud Router/NAT, and a regional GKE
  Standard cluster;
- private ARM nodes (`n4a-standard-4`, 2 desired/min, 4 max);
- DNS endpoint with external IAM access and **no IP endpoints**;
- Cloud SQL PG16 regional HA/private IP/backups/PITR;
- Redis 7 Standard HA/private service access/AUTH/TLS;
- Secret Manager bundles, WIF principals, ESO, and fixed ExternalSecrets;
- global static IP and the GCE ingress overlay dependencies;
- Datadog STS integration, Agent, managed assets, and DBM prerequisites;
- environment-specific GCS state only.

Reject any public GKE node, public control-plane IP endpoint, Cloud SQL public
IP, Basic Redis, disabled AUTH/TLS, service-account key, plaintext secret,
x86/T2A substitution, shared production resource, or destroy/replace outside
the new sandbox project.

## 14. Admin: first sandbox infra apply

After approval, change only:

```text
DISTR_DRY_RUN=0
GATEWAY_AUTO_DEPLOY=false
```

Trigger one infra run. Do not run concurrent applies. Require successful
platform verification and Secret Manager/ESO setup before continuing.

## 15. Admin: create and connect the sandbox Helm deployment

Create the `api-gateway` Helm deployment:

- deployment/target name = gateway deployment name;
- namespace = same gateway deployment name;
- Helm release = same gateway deployment name;
- leave values empty; the infra runner owns the generated fragment.

Copy the Hub Kubernetes-agent connect command and run:

```bash
bash scripts/connect-k8s-agent.sh sandbox <SANDBOX_INFRA_DEPLOY_NAME> \
  'kubectl apply -n <SANDBOX_GATEWAY_DEPLOY_NAME> -f "https://app.distr.sh/api/v1/connect?..."'
```

The script obtains credentials with `--dns-endpoint`, verifies a `.gke.goog`
server, creates the namespace if needed, and waits for `distr-agent`.

## 16. Admin: second sandbox infra deploy

Set:

```text
GATEWAY_AUTO_DEPLOY=true
GATEWAY_CHART_VERSION=<PINNED_OR_SANDBOX_APPROVED_VERSION>
DISTR_DRY_RUN=0
```

Trigger a second infra run. It must regenerate the GCP Helm fragment, ensure
the app secret, wait for ESO, and update the gateway deployment. Hub hand-edits
to Helm values are not durable and must not be used to bypass the fragment.

Wait for:

- global IP assigned to the Ingress;
- Cloud DNS A record resolving to that IP;
- ManagedCertificate status `Active` (this can take tens of minutes);
- FrontendConfig HTTP→HTTPS redirect;
- BackendConfig `timeoutSec: 900`;
- migrations, gateway, router, adapter, and Distr agent ready.

## 17. FDE + Admin: enable Datadog and DBM in stages

Follow [datadog-operations.md](datadog-operations.md):

1. Establish the keyless GCP STS integration and GKE Agent.
2. Verify GCP/GKE/Cloud SQL metrics and environment tags.
3. Apply Cloud SQL DBM prerequisites and the least-privilege database user.
4. Enable the direct PostgreSQL check only after connectivity is proven.
5. Baseline database monitors in draft before publishing.

Do not put Datadog keys or the DBM password in gateway Helm values.

## 18. Admin: run sandbox smoke checks

Obtain Cloud SQL and Redis instance names from the reviewed Terraform outputs
or runner log, then run:

```bash
bash scripts/smoke-checks.sh sandbox \
  <SANDBOX_INFRA_DEPLOY_NAME> \
  <SANDBOX_GATEWAY_DEPLOY_NAME> \
  <SANDBOX_DOMAIN_NAME> \
  <SANDBOX_CLOUDSQL_INSTANCE> \
  <SANDBOX_REDIS_INSTANCE>
```

Optionally add an authenticated inference smoke without writing the key:

```bash
read -r -s SMOKE_API_KEY
export SMOKE_API_KEY
export SMOKE_MODEL='<registered-model-group>'
bash scripts/smoke-checks.sh sandbox <infra> <gateway> <domain> <sql> <redis>
unset SMOKE_API_KEY SMOKE_MODEL
```

The script checks GKE DNS access, ARM/N4A nodes, Cloud SQL, Redis security, ESO,
fixed Secrets, rollouts, ingress resources, Datadog Agent, redirect, and public
health/readiness.

Also verify dashboard login, user invitation/SSO, an org API key, rate limits,
and a test provider route. Record evidence and leave the sandbox running for the
agreed soak.

## 19. Admin: promote independently to production

First complete the approved platform-only sandbox teardown and rebuild in
[rollback-teardown.md](rollback-teardown.md). Retain the sandbox foundation VM,
state bucket, and project; destroy/recreate the Distr-managed platform, then
repeat both Distr passes, Datadog checks, rotation, smoke checks, and selected
failure recovery without undocumented steps.

Present that evidence, a current cost estimate, and the production foundation/
platform plans. Do not continue without explicit production approval.
Production is a new deployment, not a state/data clone:

1. Pin the exact sandbox-approved infra and gateway Application versions.
2. In `bootstrap/terraform.tfvars`, set
   `enabled_environments = ["sandbox", "prod"]`.
3. Run `bootstrap.sh --plan`; require an unchanged sandbox and production-only
   project, budget, state bucket, network, service account, and VM additions.
4. After approval, run `bootstrap.sh --apply` and `preflight.sh prod`.
5. Grant the production service account access to the approved DNS project/
   zone, then recheck DNS and N4A/data-service quota.
6. Create production-specific Hub secrets and env from the sample.
7. Repeat Docker connect, dry-run review, first apply, Kubernetes-agent connect,
   second apply, Datadog stages, and smoke checks with `prod`.
8. Confirm production DNS and certificate independently.
9. Keep sandbox available until production completes its soak and rollback
   owners accept the result.

Never copy the sandbox Secret Manager `app` bundle into production; production
must generate independent crypto/router material. Do not restore an AWS
snapshot or cache into this greenfield path.

## 20. Handoff

Record:

- project IDs/numbers, region/zones, CIDRs, DNS zone/hostname/static IP;
- state buckets/prefixes and owners;
- pinned Distr Application versions and image digests;
- GKE version/release channel, node pool, Cloud SQL and Redis names;
- WIF principals, service accounts, and IAM reviewers;
- Datadog integration/account IDs, env tags, dashboards, and monitor state;
- smoke/soak evidence, rotation owners, upgrade window, rollback owners;
- explicit statement that AWS migration and GPU provisioning were not part of
  this deployment.
