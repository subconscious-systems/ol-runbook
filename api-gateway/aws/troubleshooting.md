# Troubleshooting (AWS API Gateway)

Common failure modes for Assisted Self-Managed AWS deploys.

Architecture: [README.md](README.md) · Setup: [instructions.md](instructions.md) · Secrets: [gateway-secrets.md](gateway-secrets.md) · Rotation: [secret-rotation.md](secret-rotation.md) · Rollback: [rollback.md](rollback.md) · Teardown: [teardown.md](teardown.md) · Bootstrap: [bootstrap/](bootstrap/).

## Day-0 / Distr

### `entitlement required` / registry pull denied

The Docker agent is connected, but the customer org cannot pull `registry.distr.sh/.../api-gateway-infra/runner` (or gateway images).

This is **not** fixed by creating a Docker or Kubernetes deployment target.

Vendor portal → **Licenses** → customer → grant:

1. Application entitlement for **api-gateway-infra** (and later **api-gateway**)
2. Artifact entitlement including the runner image, chart, and gateway images

Confirm the compose/chart tags were published.

### Runner `Exited (1)` / healthcheck confusion

Two different signals:

1. **`Exited (1)`**: entrypoint failed before idle. Hub may loop “not in running state” because Distr re-runs `compose up`. Common causes: Terraform apply failure (including Datadog metric-tag 409 / dashboard tag policy). Secrets are ensured only **after** a successful apply.
2. Health can pass while Terraform is still running; exit 1 afterward means apply (or a later step) failed.

Missing K8s agent target does **not** hard-fail the runner. Keep
`GATEWAY_AUTO_DEPLOY=false` until the target exists; if enabled early,
auto-deploy soft-skips. Auto-deploy looks up the target named
`GATEWAY_DISTR_PORTAL_NAME` (defaults to `GATEWAY_DISTR_DEPLOYMENT_NAME`).
After a Hub-only rename, set `GATEWAY_DISTR_PORTAL_NAME` rather than changing
the cluster identity. Logs: `no Distr deployment target named …`.

#### Debug on the bootstrap EC2

```bash
cd api-gateway/aws/bootstrap
./scripts/connect.sh help
./scripts/connect.sh shell <DEPLOY_NAME>   # SSM shell + kubeconfig refresh
# or: ./scripts/connect.sh                  # SSM shell only
```

On the box:

```bash
export HOME=/root KUBECONFIG=/root/.kube/config
docker ps -a --filter name=runner
docker logs --tail 200 distr-*-runner-1
# look for terraform Error: / [runner] ERROR

kubectl -n <GATEWAY_DISTR_DEPLOYMENT_NAME> get pods,deploy,svc
kubectl -n <GATEWAY_DISTR_DEPLOYMENT_NAME> logs deploy/<name> --tail=200
```

### Infra apply fails: `api_key and app_key or orgUUID must be set`

The Datadog Terraform provider used to validate credentials even when
`DATADOG_ENABLED=false`. Empty Hub `DD_API_KEY` / `DD_APP_KEY` then failed
before any cloud resources. Select an `api-gateway-infra` release that skips
provider validation when Datadog is off. Do not paste dummy keys. Hub secrets
can stay empty until Datadog is enabled.

### Datadog metric-tag ensure failed / flaky API

Terraform runs a Datadog metric-tag ensure script during apply. 409 / rate-limit / timeout failures can fail the whole infra run. Re-run the infra job; upserts are idempotent. Secrets are ensured only after a successful apply.

### Datadog AWS CloudWatch metrics missing

When `DATADOG_ENABLED=true`, RDS, ElastiCache, and ALB widgets expect Datadog's
normal AWS integration. Connect the AWS account in Datadog (Integrations →
Amazon Web Services → Set Permissions) with Datadog's default read-only
policy, then enable metric collection for `AWS/RDS`, `AWS/ElastiCache`, and
`AWS/ApplicationELB`. Do not create `DatadogApiGatewayIntegrationRole`. The
infra runner does not manage that integration. A leftover Hub field
`DATADOG_AWS_DATABASE_METRICS_ENABLED` is ignored.

Empty charts after a new connect are usually CloudWatch delay. Do not work
around missing metrics by enabling the Datadog log forwarder.

### Why can’t I just kubectl from my laptop?

Day-0 EKS API is CIDR-locked to the bootstrap host EIP. Your laptop is not on that path by default. Use `./scripts/connect.sh` and run `kubectl` **on the bootstrap host**. Day-0 dashboard admin should use the identity-bootstrap Job, not kubectl (see [FAQ.md](../../FAQ.md#how-is-the-initial-dashboard-admin-created)).

### First run / second infra deploy

First infra run builds the platform and prepares SM/ESO secrets with
`GATEWAY_AUTO_DEPLOY=false`. Connect the K8s target with
`connect-k8s-agent.sh <DEPLOY_NAME> '<Hub command>'`; the explicit first
argument selects the EKS cluster and the Hub command supplies the separate
gateway namespace. Then trigger a **second** infra deploy with
`GATEWAY_AUTO_DEPLOY=true` and `GATEWAY_CHART_VERSION=latest`.

The first **empty** api-gateway Helm deploy (before the K8s agent) is **expected to fail / do nothing**.

### Helm install rolled back: router Available 0/1, `/v1/models` 503

The router process is up (`/health` 200). Day-0 SMG returns `503 No models
available` because no dashboard models exist yet. Older router images treat
that 503 as startup failure, so Helm `--wait` times out and
`rollback-on-failure` uninstalls the whole release. Do not keep redeploying
the same chart. Select an `api-gateway` release whose router image treats an
empty desired-model list plus that 503 as ready. Rolling upgrades still wait
until named models appear on `/v1/models`. Do not `helm rollback` or
kubectl-patch the probe.

### Second infra / gateway auto-deploy

Fragment generation, ESO sync timing, Ingress/DNS, and Datadog asset conflicts often need a re-run or Hub/env tweak. Prefer fixing infra env fields. Hub hand-edits to gateway Helm overrides are overwritten on the next auto-deploy.

### EKS API from your laptop

Day-0 EKS API is CIDR-locked to the bootstrap host EIP. Use `./scripts/connect.sh` and run `kubectl` **on that host**, not from your laptop (unless you deliberately add your IP to `CLUSTER_ENDPOINT_PUBLIC_ACCESS_CIDRS`).

### Naming limits

Keep Distr deployment names **32 characters or fewer**. Namespace and Helm
release must equal `GATEWAY_DISTR_DEPLOYMENT_NAME`. The Hub Kubernetes target
may use `GATEWAY_DISTR_PORTAL_NAME` when it differs. See [FAQ.md](../../FAQ.md).

## Secrets / bootstrap

- Cluster SoT is AWS Secrets Manager + ESO ([gateway-secrets.md](gateway-secrets.md)). Manual gateway Helm before `gateway-secrets` exists leads to migrate Job / readiness failures.
- Day-2 rotation (csrf, encryption, RDS/Valkey redeploy, org and worker keys): [secret-rotation.md](secret-rotation.md).
- Identity-bootstrap Job password is **not** rotated on re-run. Break-glass: `ops-cli identity bootstrap` from a gateway pod when needed.
- Forbidden: AWS keys in Hub; Datadog keys in gateway Helm secrets; vendor publish token as customer `DISTR_TOKEN`.

## Export / webhook lag (platform usage behind gateway)

Laptop `kubectl` / `psql` fail because the EKS API and RDS are private (CIDR-locked to the bootstrap EC2). Do not `get-secret-value` into the terminal. Do not run `bootstrap.sh` against prod. Gateway pods are distroless — do not `kubectl exec` expecting a shell.

```bash
cd api-gateway/aws/bootstrap
./scripts/connect.sh help
./scripts/connect.sh env <INFRA_DEPLOY_NAME>
./scripts/connect.sh shell <INFRA_DEPLOY_NAME>
./scripts/connect.sh sql <INFRA_DEPLOY_NAME> --ns <GATEWAY_NS> --file scripts/sql/usage-lag.sql
./scripts/connect.sh sql <INFRA_DEPLOY_NAME> --ns <GATEWAY_NS> --file query.sql
```

`--ns` is required for `sql` (do not guess the gateway namespace from the infra name). On the box after `shell`: `sudo -i` then `export HOME=/root KUBECONFIG=/root/.kube/config`. `sql` uses a one-shot client Job because SSM is not a TTY and the host has no `psql`.

`scripts/sql/usage-lag.sql` reports `max(gateway_usage_events.received_at)` and delivery status counts (see the file header). Pending, failed, or dead_letter rows point at the webhook worker or `/api/gateway-events`. Usage insert enqueues one delivery; do not grep `NOT EXISTS` as the hot query (that skip-scan copier is gone). Rotate the RDS password if a connection URL or `SecretString` was printed.

## Database / release rollback

Migrations are additive and forward-compatible; the schema is never reverted.
Gateway version rollback is [rollback.md](rollback.md). Platform teardown is
[teardown.md](teardown.md).
