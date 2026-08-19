# Rollback (AWS)

Rollback changes desired state while preserving evidence and recoverability.

## Stabilize first

For any incident:

1. Stop new infra/gateway deployments and concurrent Terraform operations.
2. Set/keep `GATEWAY_AUTO_DEPLOY=false`.
3. Record current Distr versions, Terraform plan/state serial, EKS operations,
   pod images, Secrets Manager version numbers, RDS/Valkey state, ingress
   address/certificate, and active Datadog alerts.
4. Keep the bootstrap EC2, S3 state, old secret versions, old database/cache
   resources, and DNS intact.
5. Decide whether to fix forward or rollback one isolated layer.

Never restore an old Terraform state file over live resources, delete the EKS
cluster as incident response, or open the cluster API beyond the bootstrap
host.

## Gateway release rollback

In Distr Hub, select the previous approved gateway Application version and deploy it. Work with your support contact to ensure the previous selected version is compatible with your DB.

Do NOT run direct `helm rollback`. This will break things.

## Infrastructure release rollback

Run the previous approved infra release with plan-only first. It may be used
only when the plan is compatible with the current cloud state.

Do not expect these operations to be reversible:

- RDS storage growth;
- Secrets Manager version destruction;
- some ElastiCache and VPC/private-link changes.

After an EKS control-plane upgrade, use [eks-upgrade.md](eks-upgrade.md). AWS
permits a time-limited control-plane rollback; reject a previous release plan
that attempts to downgrade/recreate the cluster or managed data services.

For an ingress/Agent/ESO regression, a previous release can be appropriate if
its plan changes only those resources and remains compatible with the current
EKS version. Preserve the load balancer and DNS.

## Credential/data-service rollback

- **App secret:** restore only a known enabled prior version with understood
  active/previous key semantics.
- **RDS rotation:** point the `rds` bundle back to the retained old user,
  wait for ESO, and roll pods.
- **Valkey rotation:** point the `valkey` bundle back to the retained old
  instance, wait for ESO, and roll consumers.
- **RDS point-in-time recovery:** restores into a new instance. Treat it as a
  database incident/migration with application quiescence and validation, not a
  Terraform rollback.

See [secret-rotation.md](secret-rotation.md). Do not expose payloads while
changing versions.
