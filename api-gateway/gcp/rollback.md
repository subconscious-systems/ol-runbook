# Rollback (GCP)

Rollback changes desired state while preserving evidence and recoverability.

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

In Distr Hub, select the previous approved gateway Application version and deploy it. Work with your support contact to ensure the previous selected version is compatible with your DB.

Do NOT run direct `helm rollback`. This will break things.

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
