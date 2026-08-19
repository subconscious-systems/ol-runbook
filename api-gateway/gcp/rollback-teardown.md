# Rollback and teardown (GCP)

Rollback changes desired state while preserving evidence and recoverability.
Teardown permanently removes an environment in reverse dependency order. They
are different operations and require separate approvals.

## Stabilize first

For any incident:

1. Stop new infra/gateway deployments and concurrent Terraform operations.
2. Set/keep `GATEWAY_AUTO_DEPLOY=false`.
3. Record current Distr versions, Terraform plan/state serial, GKE operations,
   pod images, Secret Manager version numbers, Cloud SQL/Redis state, ingress
   address/certificate, and active Datadog alerts.
4. Keep the bootstrap VM, GCS state, old secret versions, old database/cache
   resources, and DNS intact.
5. Decide whether to fix forward or rollback one isolated layer.

Never restore an old Terraform state file over live resources, delete the GKE
cluster as incident response, or enable public/key-based access.

## Gateway release rollback

Prefer a hot fix. If the previous gateway version is required:

1. Determine whether the new release applied a database migration.
2. If schema reversion is required and supported, stop/scale new-schema
   consumers, confirm the exact down migration exists in the currently running
   image, and run the vendor-approved `ops-cli migrate-revert` command while
   that image is still present.
3. In Distr Hub, select the previous approved gateway Application version.
4. Preserve the runner-generated GCP values fragment; do not run direct `helm
   rollback`.
5. Wait for migrations/rollouts and verify dashboard, `/readyz`, org API auth,
   provider routing, ESO, Cloud SQL, Redis, ingress, and Datadog.

Direct Helm rollback breaks Distr's desired-state ownership. Database reversion
is also not automatic: reverting the app before the schema can remove the only
image containing a required down migration.

## Infrastructure release rollback

Run the previous approved infra release with plan-only first. It may be used
only when the plan is compatible with the current cloud state.

Do not expect these operations to be reversible:

- GKE control-plane minor upgrade;
- Cloud SQL storage growth;
- Secret Manager version destruction;
- project deletion;
- some Redis and private-service-access changes.

After a GKE control-plane upgrade, use fix-forward guidance in
[gke-upgrade.md](gke-upgrade.md). Reject a previous release plan that attempts
to downgrade/recreate the cluster or managed data services.

For an ingress/Agent/ESO regression, a previous release can be appropriate if
its plan changes only those resources and remains compatible with the current
GKE version. Preserve the global static IP and DNS.

## Credential/data-service rollback

- **App secret:** restore only a known enabled prior version with understood
  active/previous key semantics.
- **Cloud SQL rotation:** point the `rds` bundle back to the retained old user,
  wait for ESO, and roll pods.
- **Redis rotation:** point the `valkey` bundle back to the retained old
  instance, wait for ESO, and roll consumers.
- **Cloud SQL point-in-time recovery:** restores into a new instance. Treat it
  as a database incident/migration with application quiescence and validation,
  not a Terraform rollback.

See [secret-rotation.md](secret-rotation.md). Do not expose payloads while
changing versions.

## Planned environment teardown

Teardown production only after traffic has moved, retention/export decisions
are approved, and an independent operator has verified the target project.

### 1. Freeze and preserve evidence

- Pin/record both Distr versions and image digests.
- Set `GATEWAY_AUTO_DEPLOY=false`.
- Lower DNS TTL only through the normal DNS change window.
- Export required audit, usage, billing, and Datadog evidence.
- Confirm Cloud SQL backup/PITR requirements and create/verify the approved
  final backup/export.
- Decide Secret Manager delayed-destruction/retention and GCS state retention.
- Confirm Redis is not treated as a system of record.

### 2. Remove traffic and gateway application

1. Revoke/redirect clients and confirm no material traffic.
2. Remove the public DNS record only after the traffic owner approves.
3. Undeploy the gateway Helm Application through Distr.
4. Verify migration/cleanup Jobs are complete and application workloads are
   gone.
5. Remove the Distr Kubernetes agent last within the namespace.

Do not delete the namespace first; that can hide finalizer and load-balancer
cleanup failures.

### 3. Remove observability integrations

1. Disable direct DBM checks and database monitors.
2. Remove managed gateway monitors/dashboards only if not shared.
3. Remove the environment Datadog GCP STS account and its delegate binding.
4. Remove the Datadog Agent.
5. Verify no organization-global asset used by another environment was
   deleted.

### 4. Destroy the platform through the released infra path

Keep Hub `GCP_DELETION_PROTECTION=true` for day-to-day applies. Do not flip it
false in Hub as a teardown step. After Helm undeploy and `distr-agent`
removal, run the bootstrap wrapper; it disables live GKE / Cloud SQL /
Memorystore / Secret Manager deletion protection via `gcloud`, then
`terraform destroy`. Cloud SQL on-delete final backup stays enabled.

Use the exact release's runner image. The destroy targets only the selected
environment:

- GKE/node pools/add-ons/WIF/ESO;
- Cloud SQL, Redis, Secret Manager bundles;
- GCE Ingress/LB health checks/backends/forwarding rules/static IP/certificate;
- Cloud DNS record (not an externally shared zone);
- platform VPC/subnets/ranges/router/NAT;
- environment-scoped IAM.

It does not destroy the tfstate bucket, Datadog org integration, or bootstrap
VM/projects.

Prerequisites:

- Bootstrap Terraform applied so project/region/zone/VM outputs resolve
- IAP + OS Login access from your laptop (`gcloud`)
- Infra Docker app still present/idle on the host (the script copies Hub env
  from the runner container)
- Gateway Helm app already undeployed in Hub, then `distr-agent` removed

Copy-paste (from `api-gateway/gcp/bootstrap`):

```bash
./scripts/teardown-platform.sh --yes <sandbox|prod> <INFRA_DEPLOY_NAME> <GATEWAY_DEPLOY_NAME>
```

Example:

```bash
./scripts/teardown-platform.sh --yes sandbox acme-api-gateway-infra acme-api-gateway
```

| Arg | Meaning |
| --- | --- |
| `--yes` | Required. Refuses to destroy without it. |
| `sandbox` or `prod` | Selects the bootstrap project/VM |
| `INFRA_DEPLOY_NAME` | Infra Distr Docker / Terraform name prefix. GKE is `<name>-gke`. Must match Hub `DEPLOY_NAME`. |
| `GATEWAY_DEPLOY_NAME` | Gateway Distr Helm deploy name / Kubernetes namespace |

Optional: `RUNNER_IMAGE=registry.distr.sh/subconscious/api-gateway-infra/runner:<tag>` if image discovery fails.

The script fails if `GATEWAY_DEPLOY_NAME` still has gateway, adapter, or
router Deployments. `distr-agent` is ignored. Missing namespace is OK.
Confirm Cloud SQL backup/PITR requirements before you run it; the script does
not create an extra snapshot.

This is not a Hub infra apply. Helm-facing Terraform replace stays fail-closed
on the runner; destroy is this script only.

After destroy, inspect for orphans:

```bash
gcloud container clusters list --project="$GCP_PROJECT"
gcloud sql instances list --project="$GCP_PROJECT"
gcloud redis instances list --project="$GCP_PROJECT" --region=us-east1
gcloud compute addresses list --project="$GCP_PROJECT"
gcloud compute forwarding-rules list --project="$GCP_PROJECT"
gcloud compute backend-services list --project="$GCP_PROJECT"
gcloud secrets list --project="$GCP_PROJECT"
gcloud compute networks peerings list --project="$GCP_PROJECT"
```

Resolve finalizers and private-service-access peerings through Terraform where
possible. Do not manually delete state entries to make a destroy appear clean.

### 5. Disconnect the Docker agent

Remove/disconnect the infra Docker target in Distr, then stop its containers on
the private bootstrap VM. Keep the VM temporarily if evidence or backend
inspection remains.

### 6. Preserve or delete state

The foundation and platform use versioned GCS. Decide explicitly:

- **retain:** remove writers, retain an audited read-only group, and apply the
  customer's retention policy;
- **delete:** export the approved final state/evidence to the controlled archive,
  then remove object versions and bucket according to policy.

A Terraform backend cannot reliably delete the bucket that currently stores
its own active state. Move/export state and reinitialize to an approved
temporary backend before deleting the bucket. Never simply delete the bucket
first.

### 7. Destroy the bootstrap foundation/projects

From `api-gateway/gcp/bootstrap`, for the selected final teardown:

1. Change `protect_bootstrap_vms = false`; review/apply.
2. Inspect `enabled_environments` and ensure every enabled project is intended
   for teardown. After production is enabled, the foundation state manages both
   projects; retain the other project and split state through an approved
   procedure before any environment-specific project deletion.
3. Empty/preserve state buckets as decided.
4. Change `project_deletion_policy` from `PREVENT` to `DELETE`; review/apply.
5. Run the final reviewed destroy from a backend that will survive it.
6. Verify project deletion status and billing.

The foundation state lives in the sandbox state bucket. Keep that small
foundation while production is active. Never issue a blanket destroy to remove
only sandbox after production has been added; first move the foundation state
to a backend that will survive and perform an explicitly reviewed state split.

## Teardown acceptance

The change is complete only when:

- no client DNS/traffic points at the environment;
- both Distr targets are removed;
- no GKE, Cloud SQL, Redis, load balancer/static IP/certificate, NAT, Secret
  Manager, WIF, or environment Datadog integration remains unintentionally;
- retained backups/state/secrets have named owners and expiry;
- project billing/deletion status is recorded;
- sandbox or production resources not in scope remain intact;
- no AWS data migration or GPU resource was introduced as part of teardown.
